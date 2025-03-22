#!/bin/bash

# Function to check if NVIDIA CUDA or GPU is present
check_cuda() {
    if command -v nvcc &> /dev/null || command -v nvidia-smi &> /dev/null; then
        echo "✅ NVIDIA GPU with CUDA detected."
        return 0  # CUDA is present
    else
        echo "❌ NVIDIA GPU Not Found."
        return 1  # CUDA is not present
    fi
}

# Function to check if the system is a VPS, Laptop, or Desktop
check_system_type() {
    vps_type=$(systemd-detect-virt)
    if echo "$vps_type" | grep -qiE "kvm|qemu|vmware|xen|lxc"; then
        echo "✅ This is a VPS."
        return 0  # VPS
    elif ls /sys/class/power_supply/ | grep -q "^BAT[0-9]"; then
        echo "✅ This is a Laptop."
        return 1  # Laptop
    else
        echo "✅ This is a Desktop."
        return 2  # Desktop
    fi
}

# Function to set the API URL based on system type and CUDA presence
set_api_url() {
    check_system_type
    system_type=$?

    check_cuda
    cuda_present=$?

    if [ "$system_type" -eq 0 ]; then
        # VPS
        API_URL="https://hyper.gaia.domains/v1/chat/completions"
        API_NAME="Hyper"
    elif [ "$system_type" -eq 1 ]; then
        # Laptop
        if [ "$cuda_present" -eq 0 ]; then
            API_URL="https://flip.gaia.domains/v1/chat/completions"
            API_NAME="Flip"
        else
            API_URL="https://hyper.gaia.domains/v1/chat/completions"
            API_NAME="Hyper"
        fi
    elif [ "$system_type" -eq 2 ]; then
        # Desktop
        if [ "$cuda_present" -eq 0 ]; then
            API_URL="https://gadao.gaia.domains/v1/chat/completions"
            API_NAME="Gadao"
        else
            API_URL="https://hyper.gaia.domains/v1/chat/completions"
            API_NAME="Hyper"
        fi
    fi

    echo "🔗 Using API: ($API_NAME)"
}

# Set the API URL based on system type and CUDA presence
set_api_url

# Check if jq is installed, and if not, install it
if ! command -v jq &> /dev/null; then
    echo "❌ jq not found. Installing jq..."
    sudo apt update && sudo apt install jq -y
    if [ $? -eq 0 ]; then
        echo "✅ jq installed successfully!"
    else
        echo "❌ Failed to install jq. Please install jq manually and re-run the script."
        exit 1
    fi
else
    echo "✅ jq is already installed."
fi

# Function to get a random general question based on the API URL
generate_random_general_question() {
    if [[ "$API_URL" == "https://hyper.gaia.domains/v1/chat/completions" || \
          "$API_URL" == "https://gadao.gaia.domains/v1/chat/completions" || \
          "$API_URL" == "https://flip.gaia.domains/v1/chat/completions" ]]; then
        
        JSON_URL="https://raw.githubusercontent.com/aryanzyraj/kite/main/questions.json"
        questions=$(curl -s "$JSON_URL")

        if command -v jq &>/dev/null; then
            question=$(echo "$questions" | jq -r '.[]' | shuf -n 1)
            echo "$question"
        else
            echo "Error: jq is not installed. Please install jq to parse JSON."
        fi
    else
        echo "Error: Unsupported API_URL"
    fi
}


# Function to handle the API request
send_request() {
    local message="$1"
    local api_key="$2"

    echo "📬 Sending Question to $API_NAME: $message"

    json_data=$(cat <<EOF
{
    "messages": [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "$message"}
    ]
}
EOF
    )

    response=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
        -H "Authorization: Bearer $api_key" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "$json_data")

    http_status=$(echo "$response" | tail -n 1)
    body=$(echo "$response" | head -n -1)

    # Extract the 'content' from the JSON response using jq (Suppress errors)
    response_message=$(echo "$body" | jq -r '.choices[0].message.content' 2>/dev/null)

    if [[ "$http_status" -eq 200 ]]; then
        if [[ -z "$response_message" ]]; then
            echo "⚠️ Response content is empty!"
        else
            ((success_count++))  # Increment success count
            echo "✅ [SUCCESS] Response $success_count Received!"
            echo "📝 Question: $message"
            echo "💬 Response: $response_message"
        fi
    else
        echo "⚠️ [ERROR] API request failed | Status: $http_status | Retrying."
        sleep 5
    fi

    # Set sleep time based on API URL
    if [[ "$API_URL" == "https://hyper.gaia.domains/v1/chat/completions" ]]; then
        echo "⏳ Fetching (hyper API)..."
        sleep 1
    elif [[ "$API_URL" == "https://flip.gaia.domains/v1/chat/completions" ]]; then
        echo "⏳ Fetching (Flip API)..."
        sleep 2
    elif [[ "$API_URL" == "https://gadao.gaia.domains/v1/chat/completions" ]]; then
        echo "⏳ Fetching..."
        sleep 1
    fi
}

API_KEY_DIR="$HOME/gaianet"
mkdir -p "$API_KEY_DIR"

API_KEY_LIST=($(ls "$API_KEY_DIR" 2>/dev/null | grep '^apikey_'))

load_existing_key() {
    if [ ${#API_KEY_LIST[@]} -eq 0 ]; then
        echo "❌ No existing API keys found."
        return
    fi

    echo "🔍 Detected existing API keys:"
    for i in "${!API_KEY_LIST[@]}"; do
        echo "$((i+1))) ${API_KEY_LIST[$i]}"
    done

    echo -n "👉 Select a key to load (Enter number): "
    read -r key_choice

    if [[ "$key_choice" =~ ^[0-9]+$ ]] && ((key_choice > 0 && key_choice <= ${#API_KEY_LIST[@]})); then
        selected_file="${API_KEY_LIST[$((key_choice-1))]}"
        api_key=$(cat "$API_KEY_DIR/$selected_file")
        echo "✅ Loaded API key from $selected_file"
    else
        echo "❌ Invalid selection. Exiting..."
        exit 1
    fi
}

save_new_key() {
    echo -n "Enter your API Key: "
    read -r api_key

    if [ -z "$api_key" ]; then
        echo "❌ Error: API Key is required!"
        exit 1
    fi

    while true; do
        echo -n "Enter a name to save this key (no spaces): "
        read -r key_name
        key_name=$(echo "$key_name" | tr -d ' ')  # Remove spaces

        if [ -z "$key_name" ]; then
            echo "❌ Error: Name cannot be empty!"
        elif [ -f "$API_KEY_DIR/apikey_$key_name" ]; then
            echo "⚠️  A key with this name already exists! Choose a different name."
        else
            echo "$api_key" > "$API_KEY_DIR/apikey_$key_name"
            chmod 600 "$API_KEY_DIR/apikey_$key_name"  # Secure the key file
            echo "✅ API Key saved as 'apikey_$key_name'"
            break
        fi
    done
}

# Main Logic
if [ ${#API_KEY_LIST[@]} -gt 0 ]; then
    echo "📂 Existing API keys detected."
    echo "1) Load an existing API key"
    echo "2) Enter a new API key"
    echo -n "👉 Choose an option (1 or 2): "
    read -r choice

    case "$choice" in
        1) load_existing_key ;;
        2) save_new_key ;;
        *) echo "❌ Invalid choice. Exiting..." && exit 1 ;;
    esac
else
    echo "🔑 No saved API keys found. Please enter a new one."
    save_new_key
fi

# Asking for duration
echo -n "⏳ How many hours do you want the bot to run? "
read -r bot_hours

# Convert hours to seconds
if [[ "$bot_hours" =~ ^[0-9]+$ ]]; then
    max_duration=$((bot_hours * 3600))
    echo "🕒 The bot will run for $bot_hours hour(s) ($max_duration seconds)."
else
    echo "⚠️ Invalid input! Please enter a number."
    exit 1
fi

# Display thread information
echo "✅ Using 1 thread..."
echo "⏳ Waiting 30 seconds before sending the first request..."
sleep 5

echo "🚀 Starting requests..."
start_time=$(date +%s)
success_count=0  # Initialize success counter

while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))

    if [[ "$elapsed" -ge "$max_duration" ]]; then
        echo "🛑 Time limit reached ($bot_hours hours). Exiting..."
        echo "📊 Total successful responses: $success_count"
        sleep 100000
        exit 0
    fi

    random_message=$(generate_random_general_question)
    send_request "$random_message" "$api_key"
done
