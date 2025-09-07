#!/bin/bash

# --- Universal Setup ---

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Unified logging setup
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$(pwd)/lvm_luks_extend_${TIMESTAMP}.log"

# Redirect all script output to both the console and the log file
exec &> >(tee -a "$LOG_FILE")

# --- Common Function Definitions ---

# Function to print colored status messages (logging is automatic via tee)
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Unified error handling function
handle_error() {
    echo -e "\n${RED}[ERROR]${NC} $1"
    echo -e "${RED}[ERROR]${NC} Script execution failed. Please check the log file: ${LOG_FILE}"
    exit 1
}

# Function to handle VG mismatch error gracefully for existing disks
handle_vg_mismatch_existing() {
    local vg_root=$1
    local vg_home=$2
    local selected_disk=$3
    local partition_num=$4

    echo
    echo -e "${RED}[ERROR]${NC} Cannot extend both / and /home because they are on different Volume Groups:"
    echo "  - / (root) is on Volume Group: ${vg_root}"
    echo "  - /home is on Volume Group: ${vg_home}"
    echo
    
    # Get LUKS UUID and check which VG this partition actually belongs to
    local partition_path="/dev/${selected_disk}${partition_num}"
    local luks_uuid=$(cryptsetup luksUUID "$partition_path")
    local luks_mapper_name="luks-$luks_uuid"
    local ACTUAL_VG=$(pvs --noheadings -o vg_name "/dev/mapper/$luks_mapper_name" | xargs)
    
    if [ -z "$ACTUAL_VG" ]; then
        echo -e "${RED}[ERROR]${NC} Could not determine which Volume Group this partition belongs to."
        return 1
    fi
    
    echo -e "${YELLOW}[INFO]${NC} This partition belongs to Volume Group: ${ACTUAL_VG}"
    echo

    # Only offer options that match the actual VG
    local available_options=()
    if [ "$ACTUAL_VG" == "$vg_root" ]; then
        available_options+=("1) Extend only / (root)")
    elif [ "$ACTUAL_VG" == "$vg_home" ]; then
        available_options+=("2) Extend only /home")
    else
        echo -e "${RED}[ERROR]${NC} This partition belongs to Volume Group '${ACTUAL_VG}' which doesn't match either / or /home."
        return 1
    fi
    
    available_options+=("3) Return to main menu")

    echo -e "${YELLOW}[WARNING]${NC} Please choose which filesystem you want to extend:"
    for option in "${available_options[@]}"; do
        echo "$option"
    done
    echo
    
    read -p "Enter your choice: " choice
    
    case $choice in
        1)
            if [[ " ${available_options[@]} " =~ "1) Extend only / (root)" ]]; then
                MOUNT_POINT="/"
                extend_single_filesystem "$selected_disk" "$partition_num" "$MOUNT_POINT"
            else
                echo -e "${RED}[ERROR]${NC} Invalid choice. This partition cannot be used to extend /."
                return 1
            fi
            ;;
        2)
            if [[ " ${available_options[@]} " =~ "2) Extend only /home" ]]; then
                MOUNT_POINT="/home"
                extend_single_filesystem "$selected_disk" "$partition_num" "$MOUNT_POINT"
            else
                echo -e "${RED}[ERROR]${NC} Invalid choice. This partition cannot be used to extend /home."
                return 1
            fi
            ;;
        3)
            # Return to main menu
            return 1
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Invalid choice. Returning to main menu."
            return 1
            ;;
    esac
}

# Function to handle VG mismatch error gracefully for new disks
handle_vg_mismatch_new() {
    local vg_root=$1
    local vg_home=$2
    local disk_name=$3

    echo
    echo -e "${RED}[ERROR]${NC} Cannot extend both / and /home because they are on different Volume Groups:"
    echo "  - / (root) is on Volume Group: ${vg_root}"
    echo "  - /home is on Volume Group: ${vg_home}"
    echo
    echo -e "${YELLOW}[WARNING]${NC} Please choose which filesystem you want to extend:"
    echo "1) Extend only / (root)"
    echo "2) Extend only /home"
    echo "3) Return to main menu"
    echo
    read -p "Enter your choice (1-3): " choice

    case $choice in
        1)
            # Extend only root
            MOUNT_POINT="/"
            extend_single_filesystem_new_disk "$disk_name" "$MOUNT_POINT"
            ;;
        2)
            # Extend only home
            MOUNT_POINT="/home"
            extend_single_filesystem_new_disk "$disk_name" "$MOUNT_POINT"
            ;;
        3)
            # Return to main menu
            return 1
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Invalid choice. Returning to main menu."
            return 1
            ;;
    esac
}

# Helper function to extend a single filesystem on existing disk
extend_single_filesystem() {
    local selected_disk=$1
    local partition_num=$2
    local mount_point=$3

    local partition_path="/dev/${selected_disk}${partition_num}"
    local lv_path=$(df --output=source "${mount_point}" | tail -n 1)
    local VG_NAME=$(lvs --noheadings -o vg_name "${lv_path}" | head -n1 | xargs)

    # Capture initial size
    initial_size=$(df -h "$mount_point" | awk 'NR==2 {print $4}')
    print_status "Initial available space on '${mount_point}' is: ${initial_size}"

    # Get LUKS UUID
    print_status "Detecting LUKS UUID..."
    local luks_uuid=$(cryptsetup luksUUID "$partition_path")
    local luks_mapper_name="luks-$luks_uuid"

    # --- Core Operations for Resized Disk ---
    print_status "Starting resize operations..."

    print_status "Rescanning disk $selected_disk..."
    echo 1 > "/sys/block/$selected_disk/device/rescan" || handle_error "Failed to rescan disk."

    print_status "Resizing partition $partition_num on $selected_disk to 100%..."
    parted "/dev/$selected_disk" resizepart "$partition_num" 100% || handle_error "Failed to resize partition."
    print_success "Partition resized successfully."

    print_status "Updating partition table..."
    partprobe "/dev/$selected_disk" || handle_error "Failed to run partprobe."
    sleep 2

    print_status "Resizing LUKS container $luks_mapper_name..."
    cryptsetup resize "$luks_mapper_name" || handle_error "Failed to resize LUKS container."
    print_success "LUKS container resized successfully."

    print_status "Resizing physical volume /dev/mapper/$luks_mapper_name..."
    pvresize "/dev/mapper/$luks_mapper_name" || handle_error "Failed to resize physical volume."
    print_success "Physical volume resized successfully."

    print_status "Extending logical volume $lv_path..."
    lvextend "$lv_path" -l +100%FREE || handle_error "Failed to extend logical volume."
    print_success "Logical volume extended successfully."

    print_status "Growing filesystem for $mount_point..."
    FS_TYPE=$(df -T "${mount_point}" | awk 'NR==2 {print $2}')
    if [[ "$FS_TYPE" == "xfs" ]]; then
        xfs_growfs "$mount_point" || handle_error "xfs_growfs failed for ${mount_point}."
    elif [[ "$FS_TYPE" == "ext4" || "$FS_TYPE" == "ext3" ]]; then
        resize2fs "$lv_path" || handle_error "resize2fs failed for ${lv_path}."
    else
        handle_error "Unsupported filesystem type on ${mount_point}: ${FS_TYPE}."
    fi
    print_success "Filesystem grown successfully."

    # --- Final Output for Resized Disk ---
    finalize_script "${mount_point}" "${initial_size}"
}

# Helper function to extend a single filesystem on new disk
extend_single_filesystem_new_disk() {
    local disk_name=$1
    local mount_point=$2

    DEVICE="/dev/${disk_name}"
    initial_size=$(df -h "$mount_point" | awk 'NR==2 {print $4}')
    print_status "Initial available space on '${mount_point}' is: ${initial_size}"

    # Automatically determine LV Path and VG Name
    LV_PATH=$(df --output=source "${mount_point}" | tail -n 1)
    VG_NAME=$(lvs --noheadings -o vg_name "${LV_PATH}" | head -n1 | xargs)
    if [ -z "$VG_NAME" ]; then
        handle_error "Could not automatically determine the Volume Group for ${mount_point}."
    fi
    print_status "Automatically detected Volume Group: ${VG_NAME}"

    # Confirmation Prompt
    PARTITION="${DEVICE}1"
    echo
    print_warning "The script will perform the following operations:"
    print_warning "  - Create new partition:   ${PARTITION}"
    print_warning "  - Encrypt with LUKS:      ${PARTITION}"
    print_warning "  - Add to Volume Group:    ${VG_NAME}"
    print_warning "  - Extend Filesystem on:   ${mount_point}"
    echo
    read -p "Do you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_status "Operation cancelled by user."
        exit 0
    fi

    # --- Core Operations for New Disk ---
    print_status "Partitioning disk ${DEVICE}..."
    parted -s "${DEVICE}" -- mklabel gpt mkpart primary 1MiB 100% || handle_error "Failed to partition ${DEVICE}."
    print_success "Disk partitioning complete."
    partprobe "${DEVICE}"
    sleep 2

    print_status "Formatting ${PARTITION} with LUKS. You will be asked to set a passphrase."
    cryptsetup luksFormat "${PARTITION}" || handle_error "LUKS formatting failed."

    LUKS_UUID=$(cryptsetup luksUUID "${PARTITION}")
    MAPPER_NAME="luks-${LUKS_UUID}"

    print_status "Opening LUKS container ${PARTITION} as ${MAPPER_NAME}."
    cryptsetup luksOpen "${PARTITION}" "${MAPPER_NAME}" || handle_error "Failed to open LUKS container."

    print_status "Creating Physical Volume on /dev/mapper/${MAPPER_NAME}."
    pvcreate "/dev/mapper/${MAPPER_NAME}" || handle_error "pvcreate failed."

    print_status "Extending Volume Group '${VG_NAME}' with the new disk."
    vgextend "${VG_NAME}" "/dev/mapper/${MAPPER_NAME}" || handle_error "vgextend failed."

    print_status "Extending the logical volume for ${mount_point}."
    lvextend "${LV_PATH}" -l +100%FREE || handle_error "lvextend failed."

    print_status "Resizing the filesystem on ${mount_point}."
    FS_TYPE=$(df -T "${mount_point}" | awk 'NR==2 {print $2}')
    if [[ "$FS_TYPE" == "xfs" ]]; then
        xfs_growfs "${mount_point}" || handle_error "xfs_growfs failed."
    elif [[ "$FS_TYPE" == "ext4" || "$FS_TYPE" == "ext3" ]]; then
        resize2fs "${LV_PATH}" || handle_error "resize2fs failed."
    else
        handle_error "Unsupported filesystem type: ${FS_TYPE}."
    fi
    print_success "Filesystem resized successfully."

    # --- System Configuration Update for New Disk ---
    print_status "Updating /etc/crypttab for automatic unlocking on boot."
    echo "${MAPPER_NAME} UUID=${LUKS_UUID} none" >> /etc/crypttab || handle_error "Failed to write to /etc/crypttab."

    print_status "Updating GRUB to include new LUKS UUID for initramfs."
    GRUB_CFG="/etc/default/grub"
    cp "${GRUB_CFG}" "${GRUB_CFG}.bak-$(date +%F)"
    sed -i.bak "s/\\(GRUB_CMDLINE_LINUX=\".*\\)\"/\\1 rd.luks.uuid=${MAPPER_NAME}\"/" ${GRUB_CFG} || handle_error "Failed to update ${GRUB_CFG}."

    print_status "Rebuilding GRUB configuration."
    grub2-mkconfig -o /boot/grub2/grub.cfg || handle_error "grub2-mkconfig failed."

    print_status "Rebuilding initramfs with dracut."
    dracut -f || handle_error "dracut failed."

    # --- Final Output for New Disk ---
    finalize_script "${mount_point}" "${initial_size}"
}

# --- Workflow 1: Add a New Disk ---

add_new_disk_workflow() {
    clear
    print_status "Starting Workflow: Add a New Disk to Extend LVM"
    echo "====================================================="

    # Ask user which mount point to extend
    echo
    print_status "Please select the mount point you want to extend:"
    echo "1) / (root)"
    echo "2) /home"
    read -p "Enter your choice (1 or 2): " fs_choice

    case $fs_choice in
        1) MOUNT_POINT="/" ;;
        2) MOUNT_POINT="/home" ;;
        *) handle_error "Invalid choice. Please run the script again and enter 1 or 2." ;;
    esac

    # Validate mount point and capture initial size
    if ! findmnt -M "$MOUNT_POINT" > /dev/null; then
        handle_error "Mount point '${MOUNT_POINT}' does not exist or is not a valid filesystem."
    fi
    initial_size=$(df -h "$MOUNT_POINT" | awk 'NR==2 {print $4}')
    print_status "Initial available space on '${MOUNT_POINT}' is: ${initial_size}"

    # Show available disks and get user input
    echo
    print_status "Listing available block devices..."
    lsblk -d -n -o NAME,SIZE | grep -E "^(sd|vd|hd)"
    echo
    read -p "Enter the name of the new disk to use: " DISK_NAME
    DEVICE="/dev/${DISK_NAME}"

    if ! lsblk "$DEVICE" >/dev/null 2>&1; then
        handle_error "Disk '${DEVICE}' does not exist or is not a valid block device."
    fi

    # Automatically determine LV Path and VG Name
    LV_PATH=$(df --output=source "${MOUNT_POINT}" | tail -n 1)
    VG_NAME=$(lvs --noheadings -o vg_name "${LV_PATH}" | head -n1 | xargs)
    if [ -z "$VG_NAME" ]; then
        handle_error "Could not automatically determine the Volume Group for ${MOUNT_POINT}."
    fi
    print_status "Automatically detected Volume Group: ${VG_NAME}"

    # Confirmation Prompt
    PARTITION="${DEVICE}1"
    echo
    print_warning "The script will perform the following operations:"
    print_warning "  - Create new partition:   ${PARTITION}"
    print_warning "  - Encrypt with LUKS:      ${PARTITION}"
    print_warning "  - Add to Volume Group:    ${VG_NAME}"
    print_warning "  - Extend Filesystem on:   ${MOUNT_POINT}"
    echo
    read -p "Do you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_status "Operation cancelled by user."
        exit 0
    fi

    # --- Core Operations for New Disk ---
    print_status "Partitioning disk ${DEVICE}..."
    parted -s "${DEVICE}" -- mklabel gpt mkpart primary 1MiB 100% || handle_error "Failed to partition ${DEVICE}."
    print_success "Disk partitioning complete."
    partprobe "${DEVICE}"
    sleep 2

    print_status "Formatting ${PARTITION} with LUKS. You will be asked to set a passphrase."
    cryptsetup luksFormat "${PARTITION}" || handle_error "LUKS formatting failed."

    LUKS_UUID=$(cryptsetup luksUUID "${PARTITION}")
    MAPPER_NAME="luks-${LUKS_UUID}"

    print_status "Opening LUKS container ${PARTITION} as ${MAPPER_NAME}."
    cryptsetup luksOpen "${PARTITION}" "${MAPPER_NAME}" || handle_error "Failed to open LUKS container."

    print_status "Creating Physical Volume on /dev/mapper/${MAPPER_NAME}."
    pvcreate "/dev/mapper/${MAPPER_NAME}" || handle_error "pvcreate failed."

    print_status "Extending Volume Group '${VG_NAME}' with the new disk."
    vgextend "${VG_NAME}" "/dev/mapper/${MAPPER_NAME}" || handle_error "vgextend failed."

    print_status "Extending the logical volume for ${MOUNT_POINT}."
    lvextend "${LV_PATH}" -l +100%FREE || handle_error "lvextend failed."

    print_status "Resizing the filesystem on ${MOUNT_POINT}."
    FS_TYPE=$(df -T "${MOUNT_POINT}" | awk 'NR==2 {print $2}')
    if [[ "$FS_TYPE" == "xfs" ]]; then
        xfs_growfs "${MOUNT_POINT}" || handle_error "xfs_growfs failed."
    elif [[ "$FS_TYPE" == "ext4" || "$FS_TYPE" == "ext3" ]]; then
        resize2fs "${LV_PATH}" || handle_error "resize2fs failed."
    else
        handle_error "Unsupported filesystem type: ${FS_TYPE}."
    fi
    print_success "Filesystem resized successfully."

    # --- System Configuration Update for New Disk ---
    print_status "Updating /etc/crypttab for automatic unlocking on boot."
    echo "${MAPPER_NAME} UUID=${LUKS_UUID} none" >> /etc/crypttab || handle_error "Failed to write to /etc/crypttab."

    print_status "Updating GRUB to include new LUKS UUID for initramfs."
    GRUB_CFG="/etc/default/grub"
    cp "${GRUB_CFG}" "${GRUB_CFG}.bak-$(date +%F)"
    sed -i.bak "s/\\(GRUB_CMDLINE_LINUX=\".*\\)\"/\\1 rd.luks.uuid=${MAPPER_NAME}\"/" ${GRUB_CFG} || handle_error "Failed to update ${GRUB_CFG}."

    print_status "Rebuilding GRUB configuration."
    grub2-mkconfig -o /boot/grub2/grub.cfg || handle_error "grub2-mkconfig failed."

    print_status "Rebuilding initramfs with dracut."
    dracut -f || handle_error "dracut failed."

    # --- Final Output for New Disk ---
    finalize_script "${MOUNT_POINT}" "${initial_size}"
}


# --- Workflow 2: Resize an Existing Disk ---

resize_existing_disk_workflow() {
    clear
    print_status "Starting Workflow: Extend LVM on a Resized Disk"
    echo "===================================================="

    # Show available disks and get user input
    print_status "Available disks on the system:"
    lsblk -d -n -o NAME,SIZE | grep -E "^(sd|vd|hd)"
    echo
    read -p "Enter the name of the resized disk : " selected_disk

    if [[ ! -b "/dev/$selected_disk" ]]; then
        handle_error "Disk /dev/$selected_disk does not exist."
    fi

    # Show partitions for the selected disk
    print_status "Partitions on /dev/$selected_disk:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "/dev/$selected_disk"
    echo
    read -p "Enter the partition number to extend : " partition_num

    if [[ ! -b "/dev/${selected_disk}${partition_num}" ]]; then
        handle_error "Partition /dev/${selected_disk}${partition_num} does not exist."
    fi
    local partition_path="/dev/${selected_disk}${partition_num}"

    # Get LUKS UUID and check which VG this partition belongs to
    print_status "Detecting LUKS UUID..."
    local luks_uuid=$(cryptsetup luksUUID "$partition_path")
    if [[ $? -ne 0 || -z "$luks_uuid" ]]; then
        handle_error "Failed to get LUKS UUID from $partition_path."
    fi
    print_success "Detected LUKS UUID: $luks_uuid"
    local luks_mapper_name="luks-$luks_uuid"

    # Check which VG this LUKS partition belongs to
    local PARTITION_VG=$(pvs --noheadings -o vg_name "/dev/mapper/$luks_mapper_name" | xargs)
    if [ -z "$PARTITION_VG" ]; then
        handle_error "Could not determine which Volume Group this partition belongs to."
    fi
    print_status "This partition belongs to Volume Group: ${PARTITION_VG}"

    # Ask user which filesystem to extend (only show filesystems in the same VG)
    echo
    print_status "Which filesystem would you like to extend?"
    
    # Check which filesystems are in the same VG
    local available_options=()
    if lvs --noheadings -o lv_name "$PARTITION_VG" | grep -q "root"; then
        available_options+=("1) / (root)")
    fi
    if lvs --noheadings -o lv_name "$PARTITION_VG" | grep -q "home"; then
        available_options+=("2) /home")
    fi

    if [ ${#available_options[@]} -eq 0 ]; then
        handle_error "No logical volumes found in Volume Group $PARTITION_VG that can be extended."
    fi

    for option in "${available_options[@]}"; do
        echo "$option"
    done

    read -p "Enter your choice: " fs_choice

    local mount_point
    local lv_path
    case $fs_choice in
        1)
            if [[ " ${available_options[@]} " =~ "1) / (root)" ]]; then
                mount_point="/"
                lv_path=$(df --output=source "${mount_point}" | tail -n 1)
            else
                handle_error "Invalid choice. / (root) is not available in this Volume Group."
            fi
            ;;
        2)
            if [[ " ${available_options[@]} " =~ "2) /home" ]]; then
                mount_point="/home"
                lv_path=$(df --output=source "${mount_point}" | tail -n 1)
            else
                handle_error "Invalid choice. /home is not available in this Volume Group."
            fi
            ;;
        *)
            handle_error "Invalid choice. Please enter a valid option."
            ;;
    esac

    # Verify the selected LV is in the correct VG
    local SELECTED_VG=$(lvs --noheadings -o vg_name "${lv_path}" | head -n1 | xargs)
    if [ "$SELECTED_VG" != "$PARTITION_VG" ]; then
        handle_error "Selected filesystem is not in the same Volume Group as the partition. Cannot extend."
    fi

    if [[ ! -b "$lv_path" ]]; then
        handle_error "Logical volume for ${mount_point} does not exist or could not be detected."
    fi

    print_status "Volume Group for extension: ${PARTITION_VG}"

    # Capture initial size
    initial_size=$(df -h "$mount_point" | awk 'NR==2 {print $4}')
    print_status "Initial available space on '${mount_point}' is: ${initial_size}"

    # Confirmation Prompt
    echo
    print_warning "About to perform the following operations:"
    echo "• Resize partition ${partition_path}"
    echo "• Resize LUKS container /dev/mapper/${luks_mapper_name}"
    echo "• Resize Physical Volume on the LUKS container"
    echo "• Extend Logical Volume ${lv_path}"
    echo "• Grow filesystem on ${mount_point}"
    echo
    read -p "Do you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_status "Operation cancelled by user."
        exit 0
    fi

    # --- Core Operations for Resized Disk ---
    print_status "Starting resize operations..."

    print_status "Rescanning disk $selected_disk..."
    echo 1 > "/sys/block/$selected_disk/device/rescan" || handle_error "Failed to rescan disk."

    print_status "Resizing partition $partition_num on $selected_disk to 100%..."
    parted "/dev/$selected_disk" resizepart "$partition_num" 100% || handle_error "Failed to resize partition."
    print_success "Partition resized successfully."

    print_status "Updating partition table..."
    partprobe "/dev/$selected_disk" || handle_error "Failed to run partprobe."
    sleep 2

    print_status "Resizing LUKS container $luks_mapper_name..."
    cryptsetup resize "$luks_mapper_name" || handle_error "Failed to resize LUKS container."
    print_success "LUKS container resized successfully."

    print_status "Resizing physical volume /dev/mapper/$luks_mapper_name..."
    pvresize "/dev/mapper/$luks_mapper_name" || handle_error "Failed to resize physical volume."
    print_success "Physical volume resized successfully."

    print_status "Extending logical volume $lv_path..."
    lvextend "$lv_path" -l +100%FREE || handle_error "Failed to extend logical volume."
    print_success "Logical volume extended successfully."

    print_status "Growing filesystem for $mount_point..."
    FS_TYPE=$(df -T "${mount_point}" | awk 'NR==2 {print $2}')
    if [[ "$FS_TYPE" == "xfs" ]]; then
        xfs_growfs "$mount_point" || handle_error "xfs_growfs failed for ${mount_point}."
    elif [[ "$FS_TYPE" == "ext4" || "$FS_TYPE" == "ext3" ]]; then
        resize2fs "$lv_path" || handle_error "resize2fs failed for ${lv_path}."
    else
        handle_error "Unsupported filesystem type on ${mount_point}: ${FS_TYPE}."
    fi
    print_success "Filesystem grown successfully."

    # --- Final Output for Resized Disk ---
    finalize_script "${mount_point}" "${initial_size}"
}
# --- Workflow 3: Add a New Disk and Distribute Space Interactively ---

add_new_disk_interactive_workflow() {
    clear
    print_status "Starting Workflow: Add a New Disk and Distribute Space Interactively"
    echo "========================================================================"

    # --- Initial Disk Setup ---
    echo
    print_status "Listing available block devices..."
    lsblk -d -n -o NAME,SIZE | grep -E "^(sd|vd|hd)"
    echo
    read -p "Enter the name of the new disk to use: " DISK_NAME
    DEVICE="/dev/${DISK_NAME}"

    if ! lsblk "$DEVICE" >/dev/null 2>&1; then
        handle_error "Disk '${DEVICE}' does not exist or is not a valid block device."
    fi

    # Automatically determine LV Paths and VG Names for / and /home
    LV_PATH_ROOT=$(df --output=source "/" | tail -n 1)
    LV_PATH_HOME=$(df --output=source "/home" | tail -n 1)
    VG_NAME_ROOT=$(lvs --noheadings -o vg_name "${LV_PATH_ROOT}" | head -n1 | xargs)
    VG_NAME_HOME=$(lvs --noheadings -o vg_name "${LV_PATH_HOME}" | head -n1 | xargs)

    if [ -z "$VG_NAME_ROOT" ] || [ -z "$VG_NAME_HOME" ]; then
        handle_error "Could not automatically determine the Volume Groups."
    fi

    # Check if / and /home are on different VGs
    if [ "$VG_NAME_ROOT" != "$VG_NAME_HOME" ]; then
        handle_vg_mismatch_new "$VG_NAME_ROOT" "$VG_NAME_HOME" "$DISK_NAME"
        return $?
    fi

    # If we reach here, both are on the same VG
    VG_NAME="$VG_NAME_ROOT"
    print_status "Detected Volume Group: ${VG_NAME}"

    initial_size_root=$(df -h "/" | awk 'NR==2 {print $4}')
    initial_size_home=$(df -h "/home" | awk 'NR==2 {print $4}')

    # Confirmation for initial operations
    PARTITION="${DEVICE}1"
    echo
    print_warning "The script will first prepare the new disk:"
    print_warning "  - Create new partition:   ${PARTITION}"
    print_warning "  - Encrypt with LUKS:      ${PARTITION}"
    print_warning "  - Add to Volume Group:    ${VG_NAME}"
    echo
    read -p "Do you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_status "Operation cancelled by user."
        exit 0
    fi

    # --- Core Disk Preparation ---
    parted -s "${DEVICE}" -- mklabel gpt mkpart primary 1MiB 100% || handle_error "Failed to partition ${DEVICE}."
    partprobe "${DEVICE}" && sleep 2
    cryptsetup luksFormat "${PARTITION}" || handle_error "LUKS formatting failed."
    LUKS_UUID=$(cryptsetup luksUUID "${PARTITION}")
    MAPPER_NAME="luks-${LUKS_UUID}"
    cryptsetup luksOpen "${PARTITION}" "${MAPPER_NAME}" || handle_error "Failed to open LUKS container."
    pvcreate "/dev/mapper/${MAPPER_NAME}" || handle_error "pvcreate failed."
    vgextend "${VG_NAME}" "/dev/mapper/${MAPPER_NAME}" || handle_error "vgextend failed."
    print_success "New disk successfully added to the Volume Group '${VG_NAME}'."

    # --- Interactive Space Allocation ---
    FREE_SPACE_GB=$(vgs ${VG_NAME} --noheadings --units g | awk '{print $7}' | sed 's/[gG]//' | cut -d, -f1)

    echo
    print_status "Total new allocatable space: ${FREE_SPACE_GB}G"
    echo

    read -p "How much space (in GB) do you want to add to /? (just enter number, like 20): " ROOT_EXTEND_GB

    if ! [[ "$ROOT_EXTEND_GB" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        handle_error "Invalid input. Please enter a number."
    fi

    if (( $(echo "$ROOT_EXTEND_GB > $FREE_SPACE_GB" | bc -l) )); then
        handle_error "Cannot allocate more space than available. Max is ${FREE_SPACE_GB}G."
    fi

    HOME_EXTEND_GB=$(echo "$FREE_SPACE_GB - $ROOT_EXTEND_GB" | bc)

    # --- Final Confirmation ---
    echo
    print_warning "The following changes will be made:"
    print_warning "  - Extend / (root) by: ${ROOT_EXTEND_GB}G"
    print_warning "  - Extend /home by:    ${HOME_EXTEND_GB}G"
    echo
    read -p "Are you sure you want to proceed? (y/N): " final_confirm
    if [[ ! "$final_confirm" =~ ^[Yy]$ ]]; then
        print_status "Operation cancelled by user."
        exit 0
    fi

    # --- LVM and Filesystem Extension ---
    if (( $(echo "$ROOT_EXTEND_GB > 0" | bc -l) )); then
        print_status "Extending logical volume for /..."
        lvextend -L +${ROOT_EXTEND_GB}G "${LV_PATH_ROOT}" || handle_error "lvextend for / failed."
        print_status "Resizing filesystem on /..."
        xfs_growfs "/" || handle_error "xfs_growfs for / failed."
        print_success "/ extended successfully."
    fi

    if (( $(echo "$HOME_EXTEND_GB > 0.1" | bc -l) )); then
        print_status "Extending logical volume for /home..."
        lvextend -L +${HOME_EXTEND_GB}G "${LV_PATH_HOME}" || handle_error "lvextend for /home failed."
        print_status "Resizing filesystem on /home..."
        xfs_growfs "/home" || handle_error "xfs_growfs for /home failed."
        print_success "/home extended successfully."
    fi

    # --- System Configuration Update ---
    print_status "Updating /etc/crypttab and GRUB..."
    echo "${MAPPER_NAME} UUID=${LUKS_UUID} none" >> /etc/crypttab || handle_error "Failed to write to /etc/crypttab."
    GRUB_CFG="/etc/default/grub"
    cp "${GRUB_CFG}" "${GRUB_CFG}.bak-$(date +%F)"
    sed -i.bak "s/\\(GRUB_CMDLINE_LINUX=\".*\\)\"/\\1 rd.luks.uuid=${MAPPER_NAME}\"/" ${GRUB_CFG} || handle_error "Failed to update ${GRUB_CFG}."
    grub2-mkconfig -o /boot/grub2/grub.cfg || handle_error "grub2-mkconfig failed."
    dracut -f || handle_error "dracut failed."

    # --- Final Output ---
    final_size_root=$(df -h "/" | awk 'NR==2 {print $4}')
    final_size_home=$(df -h "/home" | awk 'NR==2 {print $4}')

    echo
    print_success "All operations completed successfully!"
    echo
    echo "======================= FINAL RESULT ======================="
    print_success "Space on / changed from ${initial_size_root} to ${final_size_root}."
    print_success "Space on /home changed from ${initial_size_home} to ${final_size_home}."
    echo
    print_status "Final Filesystem Usage:"
    df -h
    echo

    print_warning "A REBOOT IS RECOMMENDED to ensure all changes are properly applied."
    read -p "Do you want to reboot now? (y/N): " reboot_confirm
    if [[ "$reboot_confirm" =~ ^[Yy]$ ]]; then
        print_status "Rebooting system..."
        reboot
    else
        print_status "Please remember to reboot the system."
    fi

    exit 0
}


# --- Workflow 4: Resize an Existing Disk and Distribute Space Interactively ---

resize_existing_disk_interactive_workflow() {
    clear
    print_status "Starting Workflow: Resize Existing Disk and Distribute Space Interactively"
    echo "=============================================================================="

    # --- Disk and Partition Selection ---
    print_status "Available disks on the system:"
    lsblk -d -n -o NAME,SIZE | grep -E "^(sd|vd|hd)"
    echo
    read -p "Enter the name of the resized disk: " selected_disk

    if [[ ! -b "/dev/$selected_disk" ]]; then
        handle_error "Disk /dev/$selected_disk does not exist."
    fi

    print_status "Partitions on /dev/$selected_disk:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "/dev/$selected_disk"
    echo
    read -p "Enter the partition number that has been resized: " partition_num

    local partition_path="/dev/${selected_disk}${partition_num}"
    if [[ ! -b "$partition_path" ]]; then
        handle_error "Partition $partition_path does not exist."
    fi

    # --- Automatically Detect System Config ---
    local LV_PATH_ROOT=$(df --output=source "/" | tail -n 1)
    local LV_PATH_HOME=$(df --output=source "/home" | tail -n 1)
    local VG_NAME_ROOT=$(lvs --noheadings -o vg_name "${LV_PATH_ROOT}" | head -n1 | xargs)
    local VG_NAME_HOME=$(lvs --noheadings -o vg_name "${LV_PATH_HOME}" | head -n1 | xargs)
    local luks_uuid=$(cryptsetup luksUUID "$partition_path")
    local luks_mapper_name="luks-$luks_uuid"

    if [[ $? -ne 0 || -z "$luks_uuid" ]]; then
        handle_error "Failed to get LUKS UUID from $partition_path."
    fi

    # Check if / and /home are on different VGs
    if [ "$VG_NAME_ROOT" != "$VG_NAME_HOME" ]; then
        handle_vg_mismatch_existing "$VG_NAME_ROOT" "$VG_NAME_HOME" "$selected_disk" "$partition_num"
        return $?
    fi

    # If we reach here, both are on the same VG
    local VG_NAME="$VG_NAME_ROOT"
    print_status "Detected Volume Group: ${VG_NAME}"
    print_status "Detected LUKS Mapper: ${luks_mapper_name}"

    local initial_size_root=$(df -h "/" | awk 'NR==2 {print $4}')
    local initial_size_home=$(df -h "/home" | awk 'NR==2 {print $4}')

    # Determine which VG this partition belongs to
    local CURRENT_VG=$(pvs --noheadings -o vg_name "/dev/mapper/$luks_mapper_name" | xargs)
    if [ -z "$CURRENT_VG" ]; then
        handle_error "Could not determine which Volume Group this partition belongs to."
    fi
    print_status "This partition belongs to Volume Group: ${CURRENT_VG}"

    # --- Confirmation for Resize Operations ---
    echo
    print_warning "About to perform the following operations:"
    echo "• Resize partition ${partition_path}"
    echo "• Resize LUKS container /dev/mapper/${luks_mapper_name}"
    echo "• Resize Physical Volume on the LUKS container"
    echo "• Extend Logical Volume in ${CURRENT_VG}"
    echo
    read -p "Do you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_status "Operation cancelled by user."
        exit 0
    fi

    # --- Core Resize Operations ---
    print_status "Rescanning disk $selected_disk..."
    echo 1 > "/sys/block/$selected_disk/device/rescan" || handle_error "Failed to rescan disk."
    print_status "Resizing partition $partition_num on $selected_disk to 100%..."
    parted "/dev/$selected_disk" resizepart "$partition_num" 100% || handle_error "Failed to resize partition."
    partprobe "/dev/$selected_disk" || handle_error "Failed to run partprobe."
    sleep 2
    print_status "Resizing LUKS container $luks_mapper_name..."
    cryptsetup resize "$luks_mapper_name" || handle_error "Failed to resize LUKS container."
    print_status "Resizing physical volume /dev/mapper/$luks_mapper_name..."
    pvresize "/dev/mapper/$luks_mapper_name" || handle_error "Failed to resize physical volume."
    print_success "Disk, partition, and PV have been successfully resized."

    # --- Space Allocation for the specific VG ---
    FREE_SPACE_GB=$(vgs ${CURRENT_VG} --noheadings --units g | awk '{print $7}' | sed 's/[gG]//' | cut -d, -f1)

    echo
    print_status "Total new allocatable space in ${CURRENT_VG}: ${FREE_SPACE_GB}G"
    echo

    read -p "How much space (in GB) do you want to add to /? (just enter number, like 20): " ROOT_EXTEND_GB

    if ! [[ "$ROOT_EXTEND_GB" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        handle_error "Invalid input. Please enter a number."
    fi

    if (( $(echo "$ROOT_EXTEND_GB > $FREE_SPACE_GB" | bc -l) )); then
        handle_error "Cannot allocate more space than available. Max is ${FREE_SPACE_GB}G."
    fi

    HOME_EXTEND_GB=$(echo "$FREE_SPACE_GB - $ROOT_EXTEND_GB" | bc)

    # --- Final Confirmation ---
    echo
    print_warning "The following changes will be made:"
    print_warning "  - Extend / (root) by: ${ROOT_EXTEND_GB}G"
    print_warning "  - Extend /home by:    ${HOME_EXTEND_GB}G"
    echo
    read -p "Are you sure you want to proceed? (y/N): " final_confirm
    if [[ ! "$final_confirm" =~ ^[Yy]$ ]]; then
        print_status "Operation cancelled by user."
        exit 0
    fi

    # --- LVM and Filesystem Extension ---
    if (( $(echo "$ROOT_EXTEND_GB > 0" | bc -l) )); then
        print_status "Extending logical volume for /..."
        lvextend -L +${ROOT_EXTEND_GB}G "${LV_PATH_ROOT}" || handle_error "lvextend for / failed."
        print_status "Resizing filesystem on /..."
        xfs_growfs "/" || handle_error "xfs_growfs for / failed."
        print_success "/ extended successfully."
    fi

    if (( $(echo "$HOME_EXTEND_GB > 0.1" | bc -l) )); then
        print_status "Extending logical volume for /home..."
        lvextend -L +${HOME_EXTEND_GB}G "${LV_PATH_HOME}" || handle_error "lvextend for /home failed."
        print_status "Resizing filesystem on /home..."
        xfs_growfs "/home" || handle_error "xfs_growfs for /home failed."
        print_success "/home extended successfully."
    fi

    # --- Final Output ---
    final_size_root=$(df -h "/" | awk 'NR==2 {print $4}')
    final_size_home=$(df -h "/home" | awk 'NR==2 {print $4}')

    echo
    print_success "All operations completed successfully!"
    echo
    echo "======================= FINAL RESULT ======================="
    print_success "Space on / changed from ${initial_size_root} to ${final_size_root}."
    print_success "Space on /home changed from ${initial_size_home} to ${final_size_home}."
    echo
    print_status "Final Filesystem Usage:"
    df -h
    echo

    print_warning "A REBOOT IS RECOMMENDED to ensure all changes are properly applied."
    read -p "Do you want to reboot now? (y/N): " reboot_confirm
    if [[ "$reboot_confirm" =~ ^[Yy]$ ]]; then
        print_status "Rebooting system..."
        reboot
    else
        print_status "Please remember to reboot the system."
    fi

    exit 0
}


# --- Finalization Functions (Shared by workflows) ---

finalize_script() {
    local mount_point=$1
    local initial_size=$2

    echo
    print_success "All operations completed successfully!"
    echo
    echo "======================= FINAL RESULT ======================="
    local new_size=$(df -h "$mount_point" | awk 'NR==2 {print $4}')
    print_success "The available space on '${mount_point}' changed from ${initial_size} to ${new_size}."
    echo
    print_status "Final Filesystem Usage:"
    df -h
    echo

    print_warning "A REBOOT IS RECOMMENDED to ensure all changes are properly applied."
    echo
    read -p "Do you want to reboot now? (y/N): " reboot_confirm

    if [[ "$reboot_confirm" =~ ^[Yy]$ ]]; then
        print_status "Rebooting system..."
        reboot
    else
        print_status "Please remember to reboot the system."
    fi
    exit 0
}


# --- Main Script Logic ---

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root."
    exit 1
fi

# Main loop
# Main loop
while true; do
    clear
    echo "LUKS LVM Management Script - Started at: $(date)"
    echo "==================================================="
    print_status "Log file will be saved to: ${LOG_FILE}"
    echo
    print_status "Please choose the operation you want to perform:"
    echo "1) Add a new disk (extend / or /home)"
    echo "2) Add a new disk (interactively extend both / and /home)"
    echo "3) Resize an existing disk (extend / or /home)"
    echo "4) Resize an existing disk (interactively extend both / and /home)"
    echo "5) Exit"
    read -p "Enter your choice (1-5): " main_choice

    case $main_choice in
        1)
            add_new_disk_workflow
            ;;
        2)
            add_new_disk_interactive_workflow
            # If VG mismatch occurred, continue the loop instead of exiting
            if [ $? -eq 1 ]; then
                continue
            fi
            ;;
        3)
            resize_existing_disk_workflow
            ;;
        4)
            resize_existing_disk_interactive_workflow
            # If VG mismatch occurred, continue the loop instead of exiting
            if [ $? -eq 1 ]; then
                continue
            fi
            ;;
        5)
            print_status "Exiting script."
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Invalid choice. Please select a valid option."
            sleep 2
            continue
            ;;
    esac

    # If we reach here, a workflow completed successfully, so break the loop
    break
done

exit 0
