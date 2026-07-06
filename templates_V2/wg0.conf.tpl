[Interface]
Address = __WG_VM_IP__/24
PrivateKey = __WG_VM_PRIVATE_KEY__
ListenPort = 51820

[Peer]
PublicKey = __WG_OPN_PUBLIC_KEY__
AllowedIPs = 10.10.10.0/24
Endpoint = __WG_OPN_ENDPOINT__
PersistentKeepalive = 25
