#!/bin/bash

# Prompt for input
read -p "Enter new database name: " DB_NAME
read -p "Enter new database user: " DB_USER
read -s -p "Enter password for new user: " DB_PASS
echo

# SQL commands
SQL="
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
"

# Run SQL as root
echo "Running SQL commands..."
mysql -u root -p -e "$SQL"

