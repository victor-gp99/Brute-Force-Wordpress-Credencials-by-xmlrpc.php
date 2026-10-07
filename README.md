# WordPress XML-RPC Brute Forcer

Dos scripts en Bash para probar credenciales contra el endpoint `xmlrpc.php` de WordPress durante pruebas de penetracion autorizadas. Uno opera intento por intento (serial); el otro amplifica con `system.multicall` para probar cientos de credenciales por peticion HTTP.

---

## Uso autorizado

Estas herramientas solo deben usarse contra sistemas sobre los que tengas autorizacion escrita y explicita (contrato de pentest, orden de trabajo, programa de bug bounty dentro de alcance). Probar credenciales contra sistemas ajenos sin permiso es ilegal en la mayoria de las jurisdicciones. El autor y el usuario de este repositorio son responsables de su propio uso.

---

## Requisitos

- Bash 4 o superior (usa arreglos asociativos).
- `curl` en el PATH.
- `mktemp`, `grep`, `tput` (presentes por defecto en Kali, Ubuntu y la mayoria de distros).

Probado en Kali Linux. En macOS el Bash del sistema es 3.2 y no sirve; instala uno moderno con `brew install bash`.

---

## Los dos scripts

| | `xmlrpc-bruteforce.sh` | `xmlrpc-multicall.sh` |
|---|---|---|
| Metodo | Un intento por peticion HTTP | Hasta N intentos por peticion (`system.multicall`) |
| Velocidad | Lenta | Alta (amortiza el costo HTTP) |
| Evade rate limiting por peticion | No | Parcialmente (menos peticiones) |
| Dispara lockout por cuenta | Mas tarde en modo spray | De golpe si el lote junta muchos intentos por cuenta |
| Robustez de deteccion | Alta | Alta (multicall filtra, serial confirma) |
| Cuando usarlo | Objetivo con pocas protecciones, o para entender el mecanismo | Objetivo que acepta multicall y quieres velocidad |

Ninguno sustituye a `wpscan --password-attack xmlrpc` para trabajo de produccion: wpscan ya hace multicall, maneja rate limiting y detecta el exito correctamente. Estos scripts sirven para aprender el mecanismo y para casos donde quieras control total del payload.

---

## `xmlrpc-bruteforce.sh`

Serial, multiusuario, con dos ordenes de iteracion.

### Flags

| Flag | Descripcion |
|---|---|
| `-u <usuario>` | Un solo usuario. |
| `-L <archivo>` | Lista de usuarios, uno por linea. |
| `-w <wordlist>` | Diccionario de contraseñas (obligatorio). |
| `-i <ip>` | IP o host objetivo. |
| `-U <url>` | URL completa del xmlrpc. Por defecto `http://<ip>/wordpress/xmlrpc.php`. |
| `-d <delay>` | Segundos entre intentos. Por defecto 0. |
| `-r <reintentos>` | Reintentos ante error de red por intento. Por defecto 2. |
| `-s` | Modo spray. |
| `-h` | Ayuda. |

### Modo brute vs modo spray

- **Brute (por defecto):** prueba todas las contraseñas del usuario 1, luego el usuario 2, etc. El bloqueo por cuenta te tumba al usuario 1 antes de agotar su diccionario.
- **Spray (`-s`):** prueba una contraseña contra todos los usuarios, luego la siguiente. Reparte los intentos por cuenta y retrasa el lockout por cuenta. Sigue siendo detectable por conteo de intentos por IP.

### Ejemplos

```bash
chmod +x xmlrpc-bruteforce.sh

# Un usuario
./xmlrpc-bruteforce.sh -u admin -w rockyou.txt -i 10.10.10.5 -d 1

# Lista de usuarios, fuerza bruta
./xmlrpc-bruteforce.sh -L usuarios.txt -w rockyou.txt -i 10.10.10.5 -d 1

# Lista de usuarios, spray (recomendado frente a lockout por cuenta)
./xmlrpc-bruteforce.sh -L usuarios.txt -w rockyou.txt -i 10.10.10.5 -s -d 1

# URL personalizada (sin /wordpress/)
./xmlrpc-bruteforce.sh -L usuarios.txt -w rockyou.txt -U http://victima.com/xmlrpc.php -s
```

---

## `xmlrpc-multicall.sh`

Amplifica con `system.multicall`: arma lotes de pares (usuario, contraseña) y los manda en una sola peticion.

### Flags

| Flag | Descripcion |
|---|---|
| `-u <usuario>` | Un solo usuario. |
| `-L <archivo>` | Lista de usuarios, uno por linea. |
| `-w <wordlist>` | Diccionario de contraseñas (obligatorio). |
| `-i <ip>` | IP o host objetivo. |
| `-U <url>` | URL completa del xmlrpc. Por defecto `http://<ip>/wordpress/xmlrpc.php`. |
| `-b <lote>` | Tamaño del lote multicall. Por defecto 100. Mas alto = mas rapido y mas detectable. |
| `-d <delay>` | Segundos entre lotes. Por defecto 0. |
| `-r <reintentos>` | Reintentos ante error de red por peticion. Por defecto 2. |
| `-h` | Ayuda. |

### Como funciona la deteccion

El script no parsea posicionalmente el XML de respuesta (fragil en Bash puro). Usa un esquema de dos fases:

1. **Filtro con multicall.** Cuenta cuantos `faultCode` trae la respuesta del lote. Cada fallo de autenticacion genera uno. Si hay menos `faultCode` que intentos en el lote, hay al menos un acierto adentro.
2. **Confirmacion serial.** Solo cuando un lote trae acierto, re-prueba ese lote intento por intento para señalar la credencial exacta. El caso comun (todo falla) es una sola peticion por lote, sin verificacion serial.

El multicall nunca confirma una credencial por si solo: solo decide "este lote vale la pena mirar". La confirmacion serial es la autoritativa.

### Ejemplos

```bash
chmod +x xmlrpc-multicall.sh

# Prueba primero con lote chico para ver si el objetivo acepta multicall
./xmlrpc-multicall.sh -u admin -w top100.txt -U http://victima.com/xmlrpc.php -b 20

# Lote por defecto
./xmlrpc-multicall.sh -L usuarios.txt -w rockyou.txt -i 10.10.10.5

# Lote grande, mas rapido pero mas ruidoso
./xmlrpc-multicall.sh -L usuarios.txt -w rockyou.txt -i 10.10.10.5 -b 500 -d 1
```

---

## Decisiones de fiabilidad (ambos scripts)

- **Exito solo por confirmacion positiva:** una credencial se da por valida solo con HTTP 200 + `methodResponse` sin `faultCode`. Nunca por ausencia de un mensaje de error, que produce falsos positivos cuando `curl` devuelve vacio por timeout o WAF.
- **Escapado XML** de usuario y contraseña (`&`, `<`, `>`). Sin esto, una contraseña con `&` corrompe el payload y hace perder aciertos reales.
- **Limpieza de retornos de carro** (`\r`) en diccionarios y listas con formato Windows.
- **Archivo temporal con `mktemp`**, no un archivo fijo en el directorio actual.
- **Timeouts** (`--connect-timeout`, `--max-time`) y reintentos ante error de red, separando error de red de fallo de autenticacion.
- **Deteccion de XML-RPC deshabilitado** para abortar en vez de recorrer todo el diccionario contra un endpoint muerto.
- **Resumen final** con todas las credenciales encontradas, tambien si cortas con Ctrl+C.

---

## Caveats operativos

- **Lockout:** protecciones como Wordfence cuentan intentos fallidos por IP en una ventana de tiempo, no solo por cuenta. Con multicall, un lote de 500 contra 5 usuarios son 100 intentos por cuenta en una sola peticion y dispara cualquier lockout serio de golpe. Baja `-b` y sube `-d` contra objetivos protegidos.
- **WAF:** si Cloudflare u otro WAF bloquea `/xmlrpc.php` en el borde, veras respuestas HTML o 403. El script multicall aborta al primer lote no-XMLRPC para no gastar el diccionario. Un 403 o 503 transitorio tambien lo aborta; si sospechas que fue un hipo de red, vuelve a lanzar.
- **Vigencia de multicall:** la amplificacion con `system.multicall` sigue funcionando en 2026 contra instalaciones default, pero esta cada vez mas bloqueada por WAFs, plugins de seguridad y hardening de host. Hay afirmaciones de que WordPress 4.4+ deshabilita el callback; contradicen incidentes reales recientes, asi que trata eso como dependiente de la configuracion. Prueba con un lote pequeño antes de confiar en el metodo.

---

## Metodo XML-RPC usado

Ambos scripts usan `wp.getUsersBlogs`, que requiere autenticacion y devuelve la lista de blogs del usuario en caso de exito. Un fallo responde con `faultCode` 403 y el mensaje de credenciales incorrectas.
