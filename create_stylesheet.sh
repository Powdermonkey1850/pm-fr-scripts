#!/bin/bash
# File: /home/ubuntu/scripts/create_stylesheet.sh
# Description: Prompts user for a stylesheet name and creates it in the current directory with predefined media query scaffolding.

# Prompt user for stylesheet name
read -p "Enter stylesheet name (without .css): " stylesheet_name

# Validate input
if [ -z "$stylesheet_name" ]; then
  echo "❌ No name provided. Exiting."
  exit 1
fi

# Define full filename
filename="${stylesheet_name}.css"

# Check if file already exists
if [ -f "$filename" ]; then
  echo "  File '$filename' already exists. Aborting."
  exit 1
fi

# Create the file with scaffolding
cat << 'EOF' > "$filename"
@media (max-width: 1500px) {

}

@media (max-width: 1200px) {

}

@media (max-width: 992px) {

}

@media (max-width: 768px) {

}

@media (max-width: 576px) {

}
EOF

# Confirm creation
echo "✅ Stylesheet '$filename' created successfully in $(pwd)."

~
