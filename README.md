# Brute-Force-Wordpress-Credencials-by-xmlrpc.php
This tool allows you to perform brute force attacks on WordPress websites using the XML-RPC API. By providing a username and a password dictionary, you can attempt to crack the login credentials of a WordPress site.

# Guide to Execute xmlrpc_bf.sh

This script performs a brute force attack via XML-RPC on WordPress.

## Requirements

- Bash
- Internet connection
- Execution permissions for the script

## Usage

1. Clone the repository or download the `xmlrpc_bf.sh` script.
2. Ensure the script has execution permissions. You can grant permissions with the following command:

    ```sh
    chmod +x xmlrpc_bf.sh
    ```

3. Run the script with the necessary parameters:

    ```sh
    ./xmlrpc_bf.sh -u <username> -w <wordlist> -i <ip>
    ```

    - `-u <username>`: Username you want to brute force.
    - `-w <wordlist>`: Path to the password list file to be used for the attack.
    - `-i <ip>`: host to attack

## Example

```sh
./xmlrpc_bf.sh -u admin -w /path/to/wordlist.txt -i 127.0.0.1
