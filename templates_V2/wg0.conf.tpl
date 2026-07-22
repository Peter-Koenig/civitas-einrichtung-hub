# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2025 p2d2 Contributors
#
# Licensed under the EUPL, Version 1.2 only (the "Licence");
# You may not use this work except in compliance with the Licence.
# You may obtain a copy of the Licence at:
#   https://joinup.ec.europa.eu/software/page/eupl
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the Licence is distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the Licence for the specific language governing permissions and
# limitations under the Licence.
[Interface]
Address = __WG_VM_IP__/24
PrivateKey = __WG_VM_PRIVATE_KEY__
ListenPort = 51820

[Peer]
PublicKey = __WG_OPN_PUBLIC_KEY__
AllowedIPs = 10.10.10.0/24
Endpoint = __WG_OPN_ENDPOINT__
PersistentKeepalive = 25
