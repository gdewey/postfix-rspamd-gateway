===============================================================================
  POSTFIX + SPAMASSASSIN MAIL GATEWAY - Spamhaus DQS
===============================================================================

REQUISITOS
----------
- Ubuntu 24.04 LTS
- Acceso root
- Clave DQS de Spamhaus (https://www.spamhaustech.com)
- Puerto 25 abierto en firewall


INSTALACION
-----------
1. Copiar todo este directorio al servidor:

     scp -r postfix-rspamd/ root@servidor:/opt/mail-gateway/

2. Editar domains.conf con los dominios y servidores relay:

     vim /opt/mail-gateway/domains.conf

3. Ejecutar el instalador:

     cd /opt/mail-gateway
     sudo ./install.sh

   El script preguntara:
     - Clave DQS de Spamhaus
     - Hostname del gateway (FQDN)
     - Si la clave tiene HBL habilitado (y/n)


ACTUALIZAR DOMINIOS (sin reinstalar)
-------------------------------------
1. Editar domains.conf
2. Ejecutar:

     sudo ./update-domains.sh


SERVICIOS
---------
El gateway usa 4 servicios independientes:

  +-------------------+------------------------------------------+
  | Servicio          | Funcion                                  |
  +-------------------+------------------------------------------+
  | postfix           | MTA - recibe y reenvía correo            |
  | spamassassin      | Daemon spamd - filtrado de contenido     |
  | spamass-milter    | Conecta Postfix con SpamAssassin         |
  | mail-logger       | Parser de logs, genera CSV por dominio   |
  +-------------------+------------------------------------------+

Comandos para cada servicio:

  Iniciar:
    sudo systemctl start postfix
    sudo systemctl start spamassassin
    sudo systemctl start spamass-milter
    sudo systemctl start mail-logger

  Detener:
    sudo systemctl stop mail-logger
    sudo systemctl stop spamass-milter
    sudo systemctl stop spamassassin
    sudo systemctl stop postfix

  Reiniciar:
    sudo systemctl restart postfix
    sudo systemctl restart spamassassin
    sudo systemctl restart spamass-milter
    sudo systemctl restart mail-logger

  Ver estado:
    sudo systemctl status postfix
    sudo systemctl status spamassassin
    sudo systemctl status spamass-milter
    sudo systemctl status mail-logger

  Ver estado rapido de todos:
    for s in postfix spamassassin spamass-milter mail-logger; do
      printf "%-20s %s\n" "$s" "$(systemctl is-active $s)"
    done


LOGS
----
  Logs del sistema (Postfix/SA):
    journalctl -u postfix -f
    journalctl -u spamassassin -f

  Logs por dominio (CSV):
    ls /var/log/mail-gateway/
    cat /var/log/mail-gateway/ejemplo.com/2026-03-14.csv

  Formato CSV:
    timestamp,sender,recipient,status,reason

  Statuses:
    relay  - Correo aceptado y entregado al servidor destino
    block  - Rechazado (DNSBL, SpamAssassin, adjunto peligroso, etc.)
    spam   - Marcado como spam pero entregado (score entre 5 y 15)
    defer  - Entrega temporal fallida, se reintentara
    bounce - Entrega permanentemente fallida


VERIFICACION
------------
  Verificar configuracion de SpamAssassin:
    spamassassin --lint

  Verificar configuracion de Postfix:
    postfix check

  Probar la instalacion de Spamhaus:
    Ir a http://blt.spamhaus.com y enviar un email de prueba


ESTRUCTURA DE ARCHIVOS
----------------------
  /opt/mail-gateway/              (o donde se copie el proyecto)
  ├── install.sh                  Script de instalacion
  ├── update-domains.sh           Actualizar dominios (se genera al instalar)
  ├── domains.conf                Mapeo dominio -> relay SMTP
  ├── readme.txt                  Este archivo
  ├── configs/
  │   ├── postfix/
  │   │   ├── main.cf             Configuracion principal Postfix
  │   │   ├── master.cf           Servicios Postfix (postscreen)
  │   │   ├── dnsbl-reply-map     Mensajes de rechazo Spamhaus
  │   │   ├── dnsbl_reply         Postscreen DNSBL reply
  │   │   └── header_checks       Bloqueo de adjuntos peligrosos
  │   └── spamassassin/
  │       └── local.cf            Configuracion SpamAssassin
  └── scripts/
      ├── mail-logger.py          Parser de logs en tiempo real
      └── mail-logger.service     Servicio systemd para el logger

  Archivos desplegados en el servidor:
  /etc/postfix/                   Configuracion Postfix (con clave DQS)
  /etc/spamassassin/              Configuracion SA + plugin Spamhaus DQS
  /opt/mail-gateway/scripts/      Mail logger
  /var/log/mail-gateway/          Logs CSV por dominio
  /var/lib/mail-gateway/          Estado del logger (posicion de lectura)
