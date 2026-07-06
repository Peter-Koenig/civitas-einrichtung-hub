# /etc/wireguard/wg0.conf
# Erzeugt durch install_civitas_core.sh – nicht manuell bearbeiten.
# Platzhalter werden durch modules/06_civitas.sh via sed ersetzt.
# Siehe: skriptarchitektur.md, Modul 06, setup_wireguard()

[Interface]
PrivateKey = WG_VM_PRIVATE_KEY
Address    = WG_VM_IP
ListenPort = WG_LISTEN_PORT

[Peer]
PublicKey  = WG_OPN_PUBLIC_KEY
WG_PRESHARED_KEY
Endpoint   = WG_OPN_ENDPOINT
AllowedIPs = WG_ALLOWED_IPS
PersistentKeepalive = 25
