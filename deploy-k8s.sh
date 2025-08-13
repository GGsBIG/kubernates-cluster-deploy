#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Banner
show_banner() {
    echo -e "${BLUE}"
    echo "██╗  ██╗ █████╗ ███████╗    ██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗"
    echo "██║ ██╔╝██╔══██╗██╔════╝    ██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝"
    echo "█████╔╝ ╚█████╔╝███████╗    ██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝ "
    echo "██╔═██╗ ██╔══██╗╚════██║    ██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝  "
    echo "██║  ██╗╚█████╔╝███████║    ██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║   "
    echo "╚═╝  ╚═╝ ╚════╝ ╚══════╝    ╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝   "
    echo ""
    echo "           Kubernetes 1.33 Cluster Deployment (1 Master + 2 Workers)"
    echo "                              Powered by Ansible"
    echo -e "${NC}"
}

# Check requirements
check_requirements() {
    echo -e "${YELLOW}=== Checking Requirements ===${NC}"
    
    local missing_tools=()
    
    # Check for required tools
    if ! command -v ansible &> /dev/null; then
        missing_tools+=("ansible")
    fi
    
    if ! command -v ansible-playbook &> /dev/null; then
        missing_tools+=("ansible-playbook")
    fi
    
    if ! command -v sshpass &> /dev/null; then
        echo -e "${YELLOW}Installing sshpass...${NC}"
        if command -v apt &> /dev/null; then
            sudo apt update && sudo apt install -y sshpass
        elif command -v yum &> /dev/null; then
            sudo yum install -y sshpass
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y sshpass
        elif command -v brew &> /dev/null; then
            brew install sshpass
        else
            missing_tools+=("sshpass")
        fi
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required tools: ${missing_tools[*]}${NC}"
        echo "Please install missing tools and try again:"
        echo "  Ubuntu/Debian: sudo apt install ansible sshpass"
        echo "  CentOS/RHEL: sudo yum install ansible sshpass"
        echo "  Fedora: sudo dnf install ansible sshpass"
        echo "  macOS: brew install ansible sshpass"
        exit 1
    fi
    
    # Check inventory file
    if [[ ! -f "./inventory.ini" ]]; then
        echo -e "${RED}Error: inventory.ini not found!${NC}"
        echo "Please ensure inventory.ini exists in the current directory"
        exit 1
    fi
    
    # Check if kubernetes.core collection is installed
    if ! ansible-galaxy collection list | grep -q "kubernetes.core"; then
        echo -e "${YELLOW}Installing kubernetes.core collection...${NC}"
        ansible-galaxy collection install kubernetes.core
    fi
    
    echo -e "${GREEN}✓ All requirements satisfied${NC}"
}

# SSH Setup Function
setup_ssh() {
    echo -e "${YELLOW}=== Setting Up SSH Access ===${NC}"
    
    # Configuration file
    INVENTORY_FILE="./inventory.ini"
    
    # Variables to be loaded from inventory.ini
    USERNAME=""
    USER_PASSWORD=""
    ROOT_PASSWORD=""
    SSH_KEY_PATH=""
    NODES=()
    
    # Load configuration from inventory.ini
    load_config() {
        local inventory_file="$1"
        local in_masters_section=false
        local in_workers_section=false
        local in_all_vars_section=false
        
        if [[ ! -f "$inventory_file" ]]; then
            echo -e "${RED}Error: Inventory file '$inventory_file' not found!${NC}"
            exit 1
        fi
        
        echo "Loading configuration from: $inventory_file"
        
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            
            if [[ "$line" =~ ^\[.*\]$ ]]; then
                if [[ "$line" == "[masters]" ]]; then
                    in_masters_section=true
                    in_workers_section=false
                    in_all_vars_section=false
                elif [[ "$line" == "[workers]" ]]; then
                    in_masters_section=false
                    in_workers_section=true
                    in_all_vars_section=false
                elif [[ "$line" == "[all:vars]" ]]; then
                    in_masters_section=false
                    in_workers_section=false
                    in_all_vars_section=true
                else
                    in_masters_section=false
                    in_workers_section=false
                    in_all_vars_section=false
                fi
                continue
            fi
            
            # Parse variables from [all:vars] section
            if [[ "$in_all_vars_section" == true && "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]]; then
                key=$(echo "$line" | cut -d'=' -f1)
                value=$(echo "$line" | cut -d'=' -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
                
                case "$key" in
                    "ansible_user") USERNAME="$value" ;;
                    "ansible_become_pass") USER_PASSWORD="$value" ;;
                    "ansible_ssh_private_key_file") SSH_KEY_PATH="${value/#\~/$HOME}" ;;
                esac
            fi
            
            # Parse master nodes
            if [[ "$in_masters_section" == true && "$line" =~ ^[a-zA-Z0-9-]+ ]]; then
                hostname=$(echo "$line" | awk '{print $1}')
                if [[ "$line" =~ ansible_host=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                    ip="${BASH_REMATCH[1]}"
                    NODES+=("$ip:$hostname")
                fi
            fi
            
            # Parse worker nodes
            if [[ "$in_workers_section" == true && "$line" =~ ^[a-zA-Z0-9-]+ ]]; then
                hostname=$(echo "$line" | awk '{print $1}')
                if [[ "$line" =~ ansible_host=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                    ip="${BASH_REMATCH[1]}"
                    NODES+=("$ip:$hostname")
                fi
            fi
        done < "$inventory_file"
        
        # Set ROOT_PASSWORD same as USER_PASSWORD for simplicity
        ROOT_PASSWORD="$USER_PASSWORD"
        
        # Validate required variables
        if [[ -z "$USERNAME" || -z "$USER_PASSWORD" || -z "$SSH_KEY_PATH" ]]; then
            echo -e "${RED}Error: Missing required configuration!${NC}"
            echo "Required: ansible_user, ansible_become_pass, ansible_ssh_private_key_file"
            exit 1
        fi
        
        if [[ ${#NODES[@]} -eq 0 ]]; then
            echo -e "${RED}Error: No nodes found in inventory!${NC}"
            exit 1
        fi
        
        echo "✓ Configuration loaded"
        echo "  Username: $USERNAME"
        echo "  SSH Key: $SSH_KEY_PATH"
        echo "  Nodes: ${#NODES[@]} found"
    }
    
    # Load configuration
    load_config "$INVENTORY_FILE"
    
    # Generate SSH key if not exists
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        echo "Generating SSH key..."
        mkdir -p "$(dirname "$SSH_KEY_PATH")"
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -C "admin@$(hostname)"
        echo "✓ SSH key generated"
    else
        echo "✓ SSH key exists"
    fi
    
    # Setup each node
    for node_entry in "${NODES[@]}"; do
        # Parse IP and hostname
        IFS=':' read -r node_ip hostname <<< "$node_entry"
        
        echo "----------------------------------------"
        if [[ -n "$hostname" ]]; then
            echo "Setting up: $node_ip (hostname: $hostname)"
        else
            echo "Setting up: $node_ip"
        fi
        
        # Set hostname if provided
        if [[ -n "$hostname" ]]; then
            echo "  → Setting hostname to: $hostname"
            if sshpass -p "$USER_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$USERNAME@$node_ip" "echo '$USER_PASSWORD' | sudo -S bash -c 'hostnamectl set-hostname $hostname && sed -i \"/127.0.1.1/d\" /etc/hosts && echo \"127.0.1.1 $hostname\" >> /etc/hosts'" 2>/dev/null; then
                echo "  ✓ Hostname set successfully"
            else
                echo "  ✗ Hostname setting failed"
            fi
        fi
        
        # Copy key to regular user
        echo "  → Copying key to $USERNAME@$node_ip"
        if sshpass -p "$USER_PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH.pub" "$USERNAME@$node_ip" 2>/dev/null; then
            echo "  ✓ User key copied"
        else
            echo "  ✗ User key failed"
            continue
        fi
        
        # Copy key to root
        echo "  → Copying key to root@$node_ip"
        if sshpass -p "$ROOT_PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH.pub" "root@$node_ip" 2>/dev/null; then
            echo "  ✓ Root key copied"
        else
            echo "  ✗ Root key failed"
        fi
        
        # Test connections
        echo "  → Testing connections..."
        if ssh -o ConnectTimeout=3 -o BatchMode=yes "$USERNAME@$node_ip" "echo 'User OK'" 2>/dev/null; then
            echo "  ✓ User passwordless login works"
        fi
        
        if ssh -o ConnectTimeout=3 -o BatchMode=yes "root@$node_ip" "echo 'Root OK'" 2>/dev/null; then
            echo "  ✓ Root passwordless login works"
        fi
        
        # Show current hostname for verification
        if [[ -n "$hostname" ]]; then
            current_hostname=$(ssh -o ConnectTimeout=3 -o BatchMode=yes "$USERNAME@$node_ip" "hostname" 2>/dev/null)
            if [[ "$current_hostname" == "$hostname" ]]; then
                echo "  ✓ Hostname verified: $current_hostname"
            else
                echo "  ! Hostname may need reboot to take effect"
            fi
        fi
    done
    
    echo -e "${GREEN}✓ SSH setup completed!${NC}"
}

# Deploy Kubernetes
deploy_kubernetes() {
    echo -e "${YELLOW}=== Deploying Kubernetes Cluster ===${NC}"
    
    # Test Ansible connectivity
    echo "Testing Ansible connectivity..."
    if ansible -i inventory.ini all -m ping -o; then
        echo -e "${GREEN}✓ All nodes are reachable${NC}"
    else
        echo -e "${RED}✗ Some nodes are not reachable. Please check SSH setup.${NC}"
        exit 1
    fi
    
    # Start deployment
    echo ""
    echo -e "${BLUE}Starting Kubernetes deployment...${NC}"
    echo "This process will take approximately 10-15 minutes."
    echo ""
    
    # Run the main playbook
    if ansible-playbook -i inventory.ini site.yml; then
        echo ""
        echo -e "${GREEN}🎉 Kubernetes cluster deployment completed successfully!${NC}"
    else
        echo ""
        echo -e "${RED}❌ Deployment failed. Please check the error messages above.${NC}"
        exit 1
    fi
}

# Show cluster status
show_cluster_status() {
    echo -e "${YELLOW}=== Cluster Status ===${NC}"
    
    # Get master node IP
    master_ip=$(grep -A 10 "\[masters\]" inventory.ini | grep "ansible_host=" | head -1 | sed 's/.*ansible_host=\([0-9.]*\).*/\1/')
    username=$(grep "ansible_user=" inventory.ini | cut -d'=' -f2 | tr -d ' ')
    
    if [[ -n "$master_ip" && -n "$username" ]]; then
        echo "Connecting to master node ($master_ip) to check cluster status..."
        echo ""
        
        # Get cluster nodes
        echo -e "${BLUE}Cluster Nodes:${NC}"
        ssh -o ConnectTimeout=5 "$username@$master_ip" "kubectl get nodes -o wide" || echo "Failed to get node status"
        
        echo ""
        echo -e "${BLUE}System Pods:${NC}"
        ssh -o ConnectTimeout=5 "$username@$master_ip" "kubectl get pods -A" || echo "Failed to get pod status"
        
        echo ""
        echo -e "${GREEN}Access your cluster:${NC}"
        echo "  ssh $username@$master_ip"
        echo "  kubectl get nodes"
        echo "  kubectl get pods -A"
    fi
}

# Main execution
main() {
    show_banner
    
    echo -e "${BLUE}This script will:${NC}"
    echo "1. Check system requirements"
    echo "2. Set up SSH passwordless access to all nodes"
    echo "3. Deploy Kubernetes 1.33 cluster (1 Master + 2 Workers)"
    echo "4. Install containerd, CNI, and all required components"
    echo ""
    
    read -p "Do you want to continue? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    
    echo ""
    
    # Execute steps
    check_requirements
    echo ""
    
    setup_ssh
    echo ""
    
    deploy_kubernetes
    echo ""
    
    show_cluster_status
    echo ""
    
    # Success message with Buddha
    echo -e "${GREEN}"
    echo "#                       _oo0oo_"
    echo "#                      o8888888o"
    echo "#                      88\" . \"88"
    echo "#                      (| -_- |)"
    echo "#                      0\\  =  /0"
    echo "#                    ___/\\\`---\'/___"
    echo "#                  .' \\\\|     |// '."
    echo "#                 / \\\\|||  :  |||// \\"
    echo "#                / _||||| -:- |||||- \\"
    echo "#               |   | \\\\\\  -  /// |   |"
    echo "#               | \\_|  ''\\---/''  |_/ |"
    echo "#               \\  .-\\__  '-'  ___/-. /"
    echo "#             ___'. .'  /--.--\\  \`. .'___"
    echo "#          .\"\" '<  \`.___\\_<|>_/___.' >' \"\"."
    echo "#         | | :  \`- \\\`.;\`\\ _ /\`;.\`/ - \` : | |"
    echo "#         \\  \\ \`_.   \\_ __\\ /__ _/   .-\` /  /"
    echo "#     =====\`-.____\`.___ \\_____/___.-\`___.-'====="
    echo "#                       \`=---='"
    echo "#"
    echo "#     ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo "#"
    echo "#               佛祖保佑         永無 BUG"
    echo "#               佛祖保佑         永不加班"
    echo "#               佛祖保佑      K8s 叢集穩定"
    echo "#"
    echo -e "${NC}"
    
    echo -e "${GREEN}🎊 Deployment completed successfully! 🎊${NC}"
    echo ""
    echo "Your Kubernetes 1.33 cluster is now ready!"
    echo "- 1 Master node configured"
    echo "- 2 Worker nodes joined"
    echo "- Canal CNI network installed"
    echo "- All system pods running"
    echo ""
    echo "Next steps:"
    echo "1. SSH to master node: ssh $username@$master_ip"
    echo "2. Deploy your applications: kubectl apply -f your-app.yaml"
    echo "3. Monitor cluster: kubectl get pods -A --watch"
}

# Handle Ctrl+C
trap 'echo -e "\n${RED}Deployment interrupted by user${NC}"; exit 1' INT

# Run main function
main "$@"