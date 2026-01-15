#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
COMPOSE_TLS_FILE="${SCRIPT_DIR}/docker-compose.tls.yml"
COMPOSE_CA_FILE="${SCRIPT_DIR}/docker-compose.ca.yml"
COMPOSE_CFSSL_FILE="${SCRIPT_DIR}/docker-compose.cfssl.yml"
CONTAINER_NAME="etcd"
PKI_DIR="${SCRIPT_DIR}/pki"
CERT_DIR="${PKI_DIR}/certs"

# Exit codes
EXIT_SUCCESS=0
EXIT_USER_ABORT=1
EXIT_CONTAINER_FAILED=2
EXIT_SETUP_FAILED=3

# Function to check container state
get_container_state() {
    local state
    state=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null) || true
    if [ -n "$state" ]; then
        echo "$state"
    else
        echo "not_found"
    fi
}

# Function to show container status
show_container_status() {
    echo ""
    echo "=== etcd Container Status ==="
    docker ps -a --filter "name=^${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
}

# Function to stop container if running
stop_container() {
    local state
    state=$(get_container_state)
    if [ "$state" = "running" ]; then
        echo "Stopping etcd container..."
        docker stop "$CONTAINER_NAME" > /dev/null
        echo "Container stopped."
    fi
}

# Function to remove container
remove_container() {
    echo "Removing etcd container..."
    docker rm "$CONTAINER_NAME" > /dev/null
    echo "Container removed."
}

# Function to prompt yes/no
prompt_yes_no() {
    local prompt="$1"
    local response
    while true; do
        read -rp "$prompt [y/n]: " response
        case "$response" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# Function to prompt for input with optional default
prompt_input() {
    local prompt="$1"
    local default="$2"
    local response
    if [ -n "$default" ]; then
        read -rp "$prompt [$default]: " response
        echo "${response:-$default}"
    else
        while true; do
            read -rp "$prompt: " response
            if [ -n "$response" ]; then
                echo "$response"
                break
            else
                echo "Value cannot be empty." >&2
            fi
        done
    fi
}

# Function to run etcd setup
run_etcd_setup() {
    echo ""
    echo "=== etcd Setup ==="
    
    # Handle .env file
    if [ -f "$ENV_FILE" ]; then
        echo "Existing .env file detected. Clearing contents..."
        > "$ENV_FILE"
    else
        echo "Creating new .env file..."
        touch "$ENV_FILE"
    fi
    
    # Prompt for number of nodes
    local num_nodes
    while true; do
        read -rp "How many nodes in the cluster? [1-9]: " num_nodes
        if [[ "$num_nodes" =~ ^[1-9]$ ]]; then
            break
        else
            echo "Please enter a number between 1 and 9."
        fi
    done
    
    # Write static header
    echo "REGISTRY=gcr.io/etcd-development/etcd" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Collect node names and hosts
    declare -a names
    declare -a hosts
    
    echo ""
    echo "Enter the name and host for THIS node (where the container will run):"
    names[1]=$(prompt_input "Set NAME_1 (this node)")
    hosts[1]=$(prompt_input "Set HOST_1 (this node)")
    
    # Collect remaining nodes if more than 1
    if [ "$num_nodes" -gt 1 ]; then
        echo ""
        echo "Enter names and hosts for the other cluster nodes:"
        for ((i=2; i<=num_nodes; i++)); do
            names[$i]=$(prompt_input "Set NAME_$i")
            hosts[$i]=$(prompt_input "Set HOST_$i")
        done
    fi
    
    # Prompt for other settings
    echo ""
    local etcd_version
    etcd_version=$(prompt_input "Set ETCD_VERSION" "v3.6.0")
    
    local token
    token=$(prompt_input "Set TOKEN")
    
    local data_dir
    data_dir=$(prompt_input "Set DATA_DIR" "/var/lib/etcd")
    
    # Write to .env file
    echo "# etcd configuration" >> "$ENV_FILE"
    echo "ETCD_VERSION=$etcd_version" >> "$ENV_FILE"
    echo "TOKEN=$token" >> "$ENV_FILE"
    echo "CLUSTER_STATE=new" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Write node names
    echo "# Node names" >> "$ENV_FILE"
    for ((i=1; i<=num_nodes; i++)); do
        echo "NAME_$i=${names[$i]}" >> "$ENV_FILE"
    done
    echo "" >> "$ENV_FILE"
    
    # Write node hosts
    echo "# Node hosts" >> "$ENV_FILE"
    for ((i=1; i<=num_nodes; i++)); do
        echo "HOST_$i=${hosts[$i]}" >> "$ENV_FILE"
    done
    echo "" >> "$ENV_FILE"
    
    # Build and write CLUSTER variable
    local cluster=""
    local protocol="http"
    for ((i=1; i<=num_nodes; i++)); do
        if [ $i -gt 1 ]; then
            cluster+=","
        fi
        cluster+="\${NAME_$i}=${protocol}://\${HOST_$i}:2380"
    done
    echo "# Cluster definition" >> "$ENV_FILE"
    echo "CLUSTER=$cluster" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Write data directory
    echo "# Data directory on host" >> "$ENV_FILE"
    echo "DATA_DIR=$data_dir" >> "$ENV_FILE"
    
    echo ""
    echo ".env file created successfully."
    echo "This node will use NAME_1 (${names[1]}) and HOST_1 (${hosts[1]})."
    
    # Prompt to start container
    echo ""
    if prompt_yes_no "Start etcd container now?"; then
        cd "$SCRIPT_DIR"
        
        local max_attempts=3
        local attempt=1
        local state=""
        
        while [ $attempt -le $max_attempts ]; do
            echo "Starting etcd container (attempt $attempt of $max_attempts)..."
            docker compose up -d
            
            # Wait a moment for container to start
            sleep 2
            
            # Check if container is running
            state=$(get_container_state)
            
            if [ "$state" = "running" ]; then
                echo ""
                echo "✓ etcd container is running successfully!"
                show_container_status
                
                # Update CLUSTER_STATE to existing
                echo "Updating CLUSTER_STATE to 'existing' in .env file..."
                sed -i 's/CLUSTER_STATE=new/CLUSTER_STATE=existing/' "$ENV_FILE"
                echo "CLUSTER_STATE updated."
                
                exit $EXIT_SUCCESS
            else
                echo "Attempt $attempt failed."
                if [ $attempt -lt $max_attempts ]; then
                    echo "Retrying..."
                    sleep 2
                fi
            fi
            
            ((attempt++))
        done
        
        # All attempts failed
        echo ""
        echo "✗ etcd container failed to start after $max_attempts attempts."
        show_container_status
        echo ""
        if prompt_yes_no "Run setup again?"; then
            run_etcd_setup
        else
            exit $EXIT_CONTAINER_FAILED
        fi
    else
        echo "Container not started."
        exit $EXIT_USER_ABORT
    fi
}

# Function to run etcd TLS setup
run_etcd_tls_setup() {
    echo ""
    echo "=== etcd TLS Cluster Setup ==="
    echo ""
    echo "This will set up an etcd cluster with TLS encryption."
    echo "Node 1 will become the CA server running multirootca."
    echo ""
    
    # Handle .env file
    if [ -f "$ENV_FILE" ]; then
        echo "Existing .env file detected. Clearing contents..."
        > "$ENV_FILE"
    else
        echo "Creating new .env file..."
        touch "$ENV_FILE"
    fi
    
    # Prompt for number of nodes
    local num_nodes
    while true; do
        read -rp "How many nodes in the cluster? [1-9]: " num_nodes
        if [[ "$num_nodes" =~ ^[1-9]$ ]]; then
            break
        else
            echo "Please enter a number between 1 and 9."
        fi
    done
    
    # Write static header
    echo "REGISTRY=gcr.io/etcd-development/etcd" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Collect node names and hosts
    declare -a names
    declare -a hosts
    
    echo ""
    echo "Enter the name and host for THIS node (Node 1 - CA Server):"
    names[1]=$(prompt_input "Set NAME_1 (this node/CA server)")
    hosts[1]=$(prompt_input "Set HOST_1 (this node/CA server)")
    
    # Collect remaining nodes if more than 1
    if [ "$num_nodes" -gt 1 ]; then
        echo ""
        echo "Enter names and hosts for the other cluster nodes:"
        for ((i=2; i<=num_nodes; i++)); do
            names[$i]=$(prompt_input "Set NAME_$i")
            hosts[$i]=$(prompt_input "Set HOST_$i")
        done
    fi
    
    # Prompt for other settings
    echo ""
    local etcd_version
    etcd_version=$(prompt_input "Set ETCD_VERSION" "v3.6.0")
    
    local token
    token=$(prompt_input "Set TOKEN")
    
    local data_dir
    data_dir=$(prompt_input "Set DATA_DIR" "/var/lib/etcd")
    
    local cert_dir
    cert_dir=$(prompt_input "Set CERT_DIR (certificate directory on host)" "/etc/etcd/pki")
    
    # Write to .env file
    echo "# etcd configuration" >> "$ENV_FILE"
    echo "ETCD_VERSION=$etcd_version" >> "$ENV_FILE"
    echo "TOKEN=$token" >> "$ENV_FILE"
    echo "CLUSTER_STATE=new" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Write TLS configuration
    echo "# TLS configuration" >> "$ENV_FILE"
    echo "TLS_ENABLED=true" >> "$ENV_FILE"
    echo "PKI_DIR=${PKI_DIR}" >> "$ENV_FILE"
    echo "CERT_DIR=${cert_dir}" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Write node names
    echo "# Node names" >> "$ENV_FILE"
    for ((i=1; i<=num_nodes; i++)); do
        echo "NAME_$i=${names[$i]}" >> "$ENV_FILE"
    done
    echo "" >> "$ENV_FILE"
    
    # Write node hosts
    echo "# Node hosts" >> "$ENV_FILE"
    for ((i=1; i<=num_nodes; i++)); do
        echo "HOST_$i=${hosts[$i]}" >> "$ENV_FILE"
    done
    echo "" >> "$ENV_FILE"
    
    # Build and write CLUSTER variable with HTTPS
    local cluster=""
    for ((i=1; i<=num_nodes; i++)); do
        if [ $i -gt 1 ]; then
            cluster+=","
        fi
        cluster+="\${NAME_$i}=https://\${HOST_$i}:2380"
    done
    echo "# Cluster definition (TLS)" >> "$ENV_FILE"
    echo "CLUSTER=$cluster" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Write data directory
    echo "# Data directory on host" >> "$ENV_FILE"
    echo "DATA_DIR=$data_dir" >> "$ENV_FILE"
    
    echo ""
    echo ".env file created successfully with TLS configuration."
    echo ""
    
    # Initialize PKI infrastructure
    echo "=== Initializing PKI Infrastructure ==="
    echo ""
    
    # Start cfssl container
    echo "Starting cfssl container..."
    cd "$SCRIPT_DIR"
    PKI_DIR="$PKI_DIR" CERT_DIR="$CERT_DIR" docker compose -f "$COMPOSE_CFSSL_FILE" up -d
    sleep 2
    
    # Generate Root CA
    echo ""
    echo "Generating Root CA certificate (valid for 10 years)..."
    docker exec cfssl cfssl gencert -initca /pki/root-ca-csr.json 2>/dev/null | \
        docker exec -i cfssl cfssljson -bare /pki/root-ca
    echo "Root CA generated."
    
    # Generate Intermediate CA
    echo ""
    echo "Generating Intermediate CA certificate (valid for 8 years)..."
    docker exec cfssl cfssl gencert -initca /pki/intermediate-ca-csr.json 2>/dev/null | \
        docker exec -i cfssl cfssljson -bare /pki/intermediate-ca-csr
    
    docker exec cfssl cfssl sign \
        -ca /pki/root-ca.pem \
        -ca-key /pki/root-ca-key.pem \
        -config /pki/ca-config.json \
        -profile intermediate \
        /pki/intermediate-ca-csr.csr 2>/dev/null | \
        docker exec -i cfssl cfssljson -bare /pki/intermediate-ca
    echo "Intermediate CA generated."
    
    # Create CA chain
    echo ""
    echo "Creating CA chain..."
    cat "${PKI_DIR}/intermediate-ca.pem" "${PKI_DIR}/root-ca.pem" > "${PKI_DIR}/ca-chain.pem"
    echo "CA chain created."
    
    # Generate CA server certificate for multirootca
    echo ""
    echo "Generating CA server certificate..."
    docker exec cfssl cfssl gencert \
        -ca /pki/intermediate-ca.pem \
        -ca-key /pki/intermediate-ca-key.pem \
        -config /pki/ca-config.json \
        -hostname "localhost,127.0.0.1,${hosts[1]}" \
        -profile server \
        /pki/server-csr.json 2>/dev/null | \
        docker exec -i cfssl cfssljson -bare /pki/ca-server
    echo "CA server certificate generated."
    
    # Generate certificates for this node (Node 1)
    echo ""
    echo "Generating certificates for ${names[1]}..."
    mkdir -p "${CERT_DIR}/${names[1]}"
    
    # Server cert
    docker exec cfssl cfssl gencert \
        -ca /pki/intermediate-ca.pem \
        -ca-key /pki/intermediate-ca-key.pem \
        -config /pki/ca-config.json \
        -hostname "localhost,127.0.0.1,${names[1]},${hosts[1]}" \
        -profile server \
        /pki/server-csr.json 2>/dev/null | \
        docker exec -i cfssl cfssljson -bare "/certs/${names[1]}/server"
    
    # Peer cert
    docker exec cfssl cfssl gencert \
        -ca /pki/intermediate-ca.pem \
        -ca-key /pki/intermediate-ca-key.pem \
        -config /pki/ca-config.json \
        -hostname "${names[1]},${hosts[1]}" \
        -profile peer \
        /pki/peer-csr.json 2>/dev/null | \
        docker exec -i cfssl cfssljson -bare "/certs/${names[1]}/peer"
    
    # Copy CA chain
    cp "${PKI_DIR}/ca-chain.pem" "${CERT_DIR}/${names[1]}/"
    
    echo "Node certificates generated."
    
    # Set permissions
    chmod 644 "${PKI_DIR}"/*.pem 2>/dev/null || true
    chmod 600 "${PKI_DIR}"/*-key.pem 2>/dev/null || true
    chmod 644 "${CERT_DIR}/${names[1]}"/*.pem 2>/dev/null || true
    chmod 600 "${CERT_DIR}/${names[1]}"/*-key.pem 2>/dev/null || true
    
    # Copy certificates to host cert directory
    echo ""
    echo "Copying certificates to ${cert_dir}..."
    sudo mkdir -p "$cert_dir"
    sudo cp "${CERT_DIR}/${names[1]}/"*.pem "$cert_dir/"
    sudo chmod 644 "$cert_dir"/*.pem
    sudo chmod 600 "$cert_dir"/*-key.pem
    echo "Certificates copied."
    
    # Start multirootca server
    echo ""
    if prompt_yes_no "Start multirootca CA server?"; then
        echo "Starting multirootca server..."
        PKI_DIR="$PKI_DIR" docker compose -f "$COMPOSE_CA_FILE" up -d
        sleep 2
        
        if docker ps --format '{{.Names}}' | grep -q '^multirootca$'; then
            echo "✓ multirootca CA server is running."
        else
            echo "✗ Failed to start multirootca server."
        fi
    fi
    
    # Prompt to start etcd container
    echo ""
    if prompt_yes_no "Start etcd container with TLS?"; then
        cd "$SCRIPT_DIR"
        
        local max_attempts=3
        local attempt=1
        local state=""
        
        while [ $attempt -le $max_attempts ]; do
            echo "Starting etcd container with TLS (attempt $attempt of $max_attempts)..."
            docker compose -f "$COMPOSE_TLS_FILE" up -d
            
            sleep 3
            
            state=$(get_container_state)
            
            if [ "$state" = "running" ]; then
                echo ""
                echo "✓ etcd container is running with TLS!"
                show_container_status
                
                # Update CLUSTER_STATE to existing
                echo "Updating CLUSTER_STATE to 'existing' in .env file..."
                sed -i 's/CLUSTER_STATE=new/CLUSTER_STATE=existing/' "$ENV_FILE"
                echo "CLUSTER_STATE updated."
                
                echo ""
                echo "=== TLS Setup Complete ==="
                echo ""
                echo "CA Server: https://${hosts[1]}:8888"
                echo "etcd endpoint: https://${hosts[1]}:2379"
                echo ""
                echo "To generate certificates for other nodes, run:"
                echo "  ./scripts/gen-node-certs.sh <node-name> <node-ip>"
                echo ""
                echo "To generate client certificates, run:"
                echo "  ./scripts/gen-client-cert.sh <client-name>"
                
                exit $EXIT_SUCCESS
            else
                echo "Attempt $attempt failed."
                if [ $attempt -lt $max_attempts ]; then
                    echo "Retrying..."
                    sleep 2
                fi
            fi
            
            ((attempt++))
        done
        
        echo ""
        echo "✗ etcd container failed to start after $max_attempts attempts."
        show_container_status
        echo ""
        if prompt_yes_no "Run TLS setup again?"; then
            run_etcd_tls_setup
        else
            exit $EXIT_CONTAINER_FAILED
        fi
    else
        echo ""
        echo "=== TLS Setup Complete (container not started) ==="
        echo ""
        echo "To start the etcd container later:"
        echo "  docker compose -f docker-compose.tls.yml up -d"
        echo ""
        echo "To generate certificates for other nodes:"
        echo "  ./scripts/gen-node-certs.sh <node-name> <node-ip>"
        exit $EXIT_USER_ABORT
    fi
}

# Function to handle reset
handle_reset() {
    echo ""
    if ! prompt_yes_no "Are you sure you want to reset the etcd database? This will delete all data."; then
        echo "Reset cancelled."
        exit $EXIT_USER_ABORT
    fi
    
    stop_container
    remove_container
    
    echo ""
    if prompt_yes_no "Create a new etcd database?"; then
        run_etcd_setup
    else
        echo "Exiting without creating new database."
        exit $EXIT_USER_ABORT
    fi
}

# Main script logic
echo "==============================="
echo "  etcd Docker Compose Manager"
echo "==============================="

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed or not in PATH"
    exit $EXIT_SETUP_FAILED
fi

# Check if user has permission to run docker
if ! docker info &> /dev/null; then
    echo "Error: Cannot connect to Docker daemon."
    echo "Please run this script with sudo or add your user to the docker group."
    exit $EXIT_SETUP_FAILED
fi

# Check container state
container_state=$(get_container_state)

if [ "$container_state" != "not_found" ]; then
    # Container exists (running or stopped)
    show_container_status
    
    echo "Existing etcd container detected."
    echo ""
    echo "Options:"
    echo "1) Reset etcd database"
    echo "2) Exit"
    echo ""
    
    while true; do
        read -rp "Choose an option [1-2]: " choice
        case "$choice" in
            1)
                handle_reset
                break
                ;;
            2)
                echo "Exiting."
                exit $EXIT_SUCCESS
                ;;
            *)
                echo "Please enter 1 or 2."
                ;;
        esac
    done
else
    # No container found
    echo ""
    echo "No etcd container detected."
    echo ""
    echo "Options:"
    echo "1) Set up a new etcd cluster (no encryption)"
    echo "2) Set up a new etcd cluster with TLS encryption"
    echo "3) Exit"
    echo ""
    
    while true; do
        read -rp "Choose an option [1-3]: " choice
        case "$choice" in
            1)
                run_etcd_setup
                break
                ;;
            2)
                run_etcd_tls_setup
                break
                ;;
            3)
                echo "Exiting."
                exit $EXIT_SUCCESS
                ;;
            *)
                echo "Please enter 1, 2, or 3."
                ;;
        esac
    done
fi
