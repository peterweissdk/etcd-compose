#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
CONTAINER_NAME="etcd"

# Exit codes
EXIT_SUCCESS=0
EXIT_USER_ABORT=1
EXIT_CONTAINER_FAILED=2
EXIT_SETUP_FAILED=3

# Function to check container state
get_container_state() {
    docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not_found"
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
    echo "Enter node names and hosts:"
    for ((i=1; i<=num_nodes; i++)); do
        names[$i]=$(prompt_input "Set NAME_$i")
        hosts[$i]=$(prompt_input "Set HOST_$i")
    done
    
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
    for ((i=1; i<=num_nodes; i++)); do
        if [ $i -gt 1 ]; then
            cluster+=","
        fi
        cluster+="\${NAME_$i}=http://\${HOST_$i}:2380"
    done
    echo "# Cluster definition" >> "$ENV_FILE"
    echo "CLUSTER=$cluster" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Write data directory
    echo "# Data directory on host" >> "$ENV_FILE"
    echo "DATA_DIR=$data_dir" >> "$ENV_FILE"
    
    echo ""
    echo ".env file created successfully."
    
    # List NAME variables and prompt user to choose
    echo ""
    echo "Available nodes:"
    for ((i=1; i<=num_nodes; i++)); do
        echo "$i) ${names[$i]}"
    done
    
    local node_choice
    while true; do
        read -rp "Choose which node to use for this docker-compose instance [1-$num_nodes]: " node_choice
        if [[ "$node_choice" =~ ^[1-9]$ ]] && [ "$node_choice" -le "$num_nodes" ]; then
            break
        else
            echo "Please enter a number between 1 and $num_nodes."
        fi
    done
    
    # Update docker-compose.yml with selected node
    echo ""
    echo "Updating docker-compose.yml to use NAME_$node_choice and HOST_$node_choice..."
    
    # Use sed to update the environment variables in docker-compose.yml
    sed -i "s/THIS_NAME: \"\${NAME_[0-9]*}\"/THIS_NAME: \"\${NAME_$node_choice}\"/" "$COMPOSE_FILE"
    sed -i "s/THIS_NAME: \"\${NAME}\"/THIS_NAME: \"\${NAME_$node_choice}\"/" "$COMPOSE_FILE"
    sed -i "s/THIS_IP: \"\${HOST_[0-9]*}\"/THIS_IP: \"\${HOST_$node_choice}\"/" "$COMPOSE_FILE"
    sed -i "s/THIS_IP: \"\${HOST}\"/THIS_IP: \"\${HOST_$node_choice}\"/" "$COMPOSE_FILE"
    
    echo "docker-compose.yml updated."
    
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
    echo "1) Set up a new etcd cluster database"
    echo "2) Exit"
    echo ""
    
    while true; do
        read -rp "Choose an option [1-2]: " choice
        case "$choice" in
            1)
                run_etcd_setup
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
fi
