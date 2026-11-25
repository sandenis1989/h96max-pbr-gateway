# PBR Gateway Agent

Шлюз на Debian (aarch64, TV-box) с Wi-Fi точкой доступа и policy-based routing
по трём контурам: RU-трафик напрямую, YouTube/целевые домены через локальный
DPI-обход (`zapret`/`nfqws`), всё остальное — через Hysteria 2 на VPS.
Дополнительно хост работает как Tailscale exit node с той же политикой.

Всё, что нужно для развёртывания, лежит в этом репозитории: nftables-правила,
systemd-юниты, скрипты установки/обновления и self-test. Секреты в репозиторий
не попадают — только шаблоны и `.env.example`.

---

## 1. Схема маршрутизации (3 контура)

```
                      ┌──────────────────────────── h96max (Debian, aarch64) ───────────────────────────┐
                      │                                                                                  │
  Wi-Fi клиент ──────►│ wlan0 (AP 192.168.12.1/24, hostapd, dnsmasq DHCP+DNS)                            │
  Tailscale peer ────►│ tailscale0 (exit node 0.0.0.0/0)                                                 │
                      │                                                                                  │
                      │  nft table inet pbr_fw, chain prerouting (hook prerouting, prio mangle = -150)   │
                      │                                                                                  │
                      │   lo / IPv6 / RFC1918 / 100.64/10 / multicast / 255.255.255.255 ──► accept       │
                      │                                                                                  │
                      │   ┌── daddr ∈ ru_ips ──────────────────────► КОНТУР 1: accept (напрямую)       │
                      │   │                                                                              │
                      │   ├── daddr ∈ zapret_domains, tcp 80/443, udp 443 ► queue 200 (nfqws)          │
                      │   │                                        КОНТУР 2: desync, затем напрямую     │
                      │   │                                                                              │
                      │   └── всё остальное (tcp/udp) ──► meta mark 0x1                                │
                      │                                        │                                        │
                      │  chain tproxy_hook (hook prerouting, prio mangle+10 = -140)                     │
                      │                                        ▼                                        │
                      │                       mark 0x1 ► TPROXY to :7893 (Hysteria 2)                   │
                      │                                        │                                        │
                      │  ip rule: fwmark 0x1 ──► table 100 ──► local default dev lo                     │
                      │                                        │                                        │
                      │  chain postrouting (nat, srcnat): oifname eth0 masquerade                      │
                      └────────────────────────────────────────┼────────────────────────────────────────┘
                                                               │
                                          eth0 (uplink) ───────┴──► провайдер
                                                               │
                                                     Hysteria 2 (UDP/443) ──► VPS Oslo ──► Internet
```

Контуры:

| # | Что матчится | Действие | Куда уходит |
|---|--------------|----------|-------------|
| 1 | `ip daddr @ru_ips` | `accept` (без mark) | напрямую через `eth0`, без VPN и desync |
| 2 | `ip daddr @zapret_domains`, tcp 80/443 или udp 443 | `queue num 200 bypass` | `nfqws` десинхронизирует DPI, пакет идёт напрямую |
| 3 | всё остальное (IPv4 tcp/udp) | `meta mark set 0x1` → TPROXY `:7893` | Hysteria 2 → VPS Oslo |

Особенности:

- **Приватные и служебные адреса** (`127/8`, `10/8`, `172.16/12`,
  `192.168/16`, `169.254/16`, `100.64/10`, `224/4`, `255.255.255.255`) и весь
  IPv6 принимаются без mark: LAN/DNS/DHCP/mDNS/Tailscale не уходят в туннель.
  `255.255.255.255` добавлен отдельно — иначе DHCP-discover попадал в TPROXY.
- **`ru_ips`** — interval-набор, наполняется `update-lists.sh` из
  `ipverse/rir-ip` (fallback `ipdeny.com`) и персистится в
  `/var/lib/pbr/ru_ips.nft`, который подключается через `include`.
- **`zapret_domains`** — набор IPv4, который наполняет `dnsmasq` через
  `nftset=` при резолве доменов из `config/zapret-domains.conf`.
- **TPROXY** работает в `inet`-таблице, но `tproxy`-стейтменты без указания
  семейства: `meta nfproto ipv4 … tproxy` в `inet` падает с
  `conflicting protocols specified: ip vs. unknown`.
- `queue … bypass`: если `nfqws` недоступен, пакеты не задерживаются, а идут
  напрямую (деградация вместо полного обрыва).

### Policy routing

```
ip rule add fwmark 0x1 table 100        # priority 32765
ip route replace local default dev lo table 100
```

`local default` в таблице 100 нужен, чтобы `tproxy`-пакеты доставлялись
локальному прозрачному сокету Hysteria (`:7893`).

---

## 2. Архитектура юнитов

| Юнит | Тип | Что делает |
|------|-----|-----------|
| `nftables.service` | stock + drop-in `10-no-flush.conf` | грузит `/etc/nftables.conf`; drop-in убирает глобальный `flush ruleset` на stop/reload, чтобы не сносить чужие таблицы (tailscaled) |
| `pbr-wlan0.service` | oneshot, `RemainAfterExit` | ждёт появления `wlan0` (вендорный `SKWIFI6621S` грузится ~14 с), `ip link up`, `192.168.12.1/24`, `accept_local=1`; стартует до hostapd/dnsmasq |
| `hostapd.service` | stock | AP `PBR-Gateway-WiFi` на `wlan0` |
| `dnsmasq.service` | stock + drop-in `10-after-nftables.conf` | DHCP `192.168.12.50–200`, DNS на `192.168.12.1`, `nftset`-наполнение; стартует после `nftables.service` |
| `pbr-rules.service` | oneshot, `RemainAfterExit` | `ip rule fwmark 0x1 → table 100` и `local default dev lo`; `Before=hysteria.service` |
| `pbr-ru-list.service` | oneshot | `update-lists.sh`: скачивает RU CIDR, персистит и применяет |
| `pbr-ru-list.timer` | timer | ежедневно + `RandomizedDelaySec=6h`, `Persistent=true` |
| `zapret.service` | stock | `nfqws` на queue 200; `INIT_APPLY_FW=0` — фаерволом владеет наш nftables |
| `hysteria.service` | simple | Hysteria 2 client, TPROXY `:7893` (tcp+udp), REDIRECT `:7892`; `After=network-online.target pbr-rules.service`, `Restart=on-failure`, `RestartSec=5s` |
| `tailscaled.service` | stock | exit node (`--advertise-exit-node`), `accept-dns=false` |

Порядок загрузки (упрощённо):

```
network-pre ─► pbr-wlan0 ─► hostapd ─► dnsmasq
nftables ─────────────────────────────► dnsmasq (After)
nftables ─► pbr-rules ─► hysteria (Requires)
network-online ─► hysteria / pbr-ru-list / tailscaled
```

### Сетевые параметры хоста

```
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.default.accept_local = 1   # новые iface (veth в selftest, tailscale0)
net.ipv4.conf.eth0.accept_local = 0      # WAN не должен принимать local-source
# pbr-wlan0 дополнительно: net.ipv4.conf.wlan0.accept_local = 1
```

`accept_local` обязателен: авторизованный `tailscaled` выставляет
`net.ipv4.conf.all.src_valid_mark=1`, из-за чего source-валидация
TPROXY-пакета с mark `0x1` уходит в таблицу 100 (`local default`) и падает с
`-EINVAL`. Без `accept_local` такие SYN'ы молча дропаются.

---

## 3. Состав репозитория

```
config/
  nftables.conf                     # 3 контура, tproxy_hook, masquerade, include ru_ips
  nftables-no-flush.conf            # drop-in для nftables.service
  dnsmasq.conf                      # DHCP/DNS, nftset через conf-dir
  dnsmasq-after-nftables.conf       # drop-in: старт после nftables
  zapret-domains.conf               # домены → nftset zapret_domains
  hostapd.conf.template             # шаблон AP (пароль подставляется из .env)
  hysteria.yaml.template            # шаблон клиента Hysteria 2
  NetworkManager-99-unmanaged-wlan0.conf
scripts/
  deploy.sh                         # развёртывание на хост (идемпотентно)
  install-hysteria.sh               # pinned release + sha256 (запускается на хосте)
  install-tailscale.sh              # установка/enable + advertise-exit-node
  apply-zapret-config.sh            # патч /opt/zapret/config (nfqws only)
  update-lists.sh                   # RU CIDR → /var/lib/pbr/ru_ips.nft
  pbr-rules.sh                      # ip rule + table 100
  selftest.sh                       # e2e-тест 3 контуров через netns+veth
systemd/                            # юниты, перечисленные выше
.env.example                        # шаблон секретов
AGENTS.md                           # исходное ТЗ
```

`config/hostapd.conf` и `config/hysteria.yaml` рендерятся из шаблонов при
деплое и в git не попадают (`.gitignore`).

---

## 4. Развёртывание с нуля

### Предварительные требования

- Целевой хост: Debian 13 (trixie), aarch64, root по SSH-ключу.
- Два интерфейса: `eth0` (uplink, шлюз провайдера) и `wlan0` (AP).
- Пакеты на хосте: `hostapd dnsmasq nftables curl dnsutils`.
- `zapret` установлен в `/opt/zapret` (по инструкции upstream; скрипт лишь
  патчит его конфиг).
- Hysteria 2 и Tailscale ставит `deploy.sh` (Tailscale — если ещё нет).

```bash
apt update
apt install -y hostapd dnsmasq nftables curl dnsutils
```

### Шаги

1. Клонировать репозиторий и создать `.env`:

   ```bash
   git clone <repo> pbr-gateway-agent && cd pbr-gateway-agent
   cp .env.example .env
   $EDITOR .env
   ```

   Заполнить как минимум:

   ```
   TARGET_HOST=root@192.168.0.102
   WLAN_SSID=PBR-Gateway-WiFi
   WLAN_PASSPHRASE=<пароль Wi-Fi>
   HYSTERIA_SERVER=<vps-ip>:443
   HYSTERIA_AUTH_SECRET=<пароль hysteria>
   HYSTERIA_SNI=<sni>
   HYSTERIA_TLS_INSECURE=false
   # TAILSCALE_AUTHKEY=tskey-auth-...   # опционально
   ```

2. Запустить деплой (нужен SSH-доступ к `TARGET_HOST`):

   ```bash
   bash scripts/deploy.sh
   ```

   Скрипт: включает forwarding и `accept_local`, рендерит конфиги, заливает
   их и юниты, патчит zapret, ставит Hysteria, применяет nftables/PBR,
   обновляет RU-набор и запускает Tailscale.

3. Tailscale: если `TAILSCALE_AUTHKEY` не задан — авторизовать вручную:

   ```bash
   ssh root@<host> 'tailscale up --accept-dns=false'
   ssh root@<host> 'tailscale set --advertise-exit-node --accept-dns=false'
   ```

   На части сборок `tailscale up --advertise-exit-node` флаг не применяет —
   `tailscale set` надёжнее (проверьте `tailscale status --json` →
   `Self.ExitNodeOption == true`). Затем в админке Tailscale:
   **Machines → <host> → Edit route settings → Approve** для `0.0.0.0/0` и
   `::/0` (без этого exit node не включается).

4. Self-test (запускается на хосте, создаёт временный netns+veth):

   ```bash
   scp scripts/selftest.sh root@<host>:/usr/local/bin/
   ssh root@<host> 'chmod +x /usr/local/bin/selftest.sh && /usr/local/bin/selftest.sh'
   ```

   Ожидаемо: `exit_ip_via_vpn=<VPS IP>`, `udp_dns=<ip>`,
   `youtube_http=200`, `ya_http=302`.

5. Проверить и перезагрузить:

   ```bash
   ssh root@<host> 'systemctl is-active pbr-wlan0 hostapd dnsmasq pbr-rules \
     nftables zapret hysteria tailscaled'
   ssh root@<host> 'systemctl reboot'
   ```

   После ребута повторить self-test — все правила, наборы и юниты должны
   восстановиться сами.

### Обновление списков

`pbr-ru-list.timer` обновляет RU-набор ежедневно. Вручную:

```bash
ssh root@<host> /usr/local/bin/update-lists.sh
```

---

## 5. Диагностика

```bash
# правила и маршруты
ip rule
ip route show table 100
nft list table inet pbr_fw
nft list set inet pbr_fw lan_ifaces
nft list set inet pbr_fw ru_ips | tail -1

# счётчики контуров (растут при трафике)
nft list chain inet pbr_fw prerouting
nft list chain inet pbr_fw tproxy_hook

# AP/DNS/DHCP
iw dev wlan0 info
iw dev wlan0 station dump
ss -lnup | grep -E ':53|:67'
journalctl -u hostapd -u dnsmasq -u hysteria -b

# проверка контуров
dig +short @192.168.12.1 example.com
curl -s https://api.ipify.org            # напрямую = IP провайдера
```

### Известные грабли (уже учтены)

- **DHCP не работает, клиент отваливается через ~18 с (DEAUTH reason 3).**
  `255.255.255.255` не входит в `224.0.0.0/4`; без отдельного `accept` запрос
  уходил в TPROXY. В конфиге есть `ip daddr 255.255.255.255 accept`.
- **После авторизации Tailscale перестаёт работать VPN-контур.**
  `tailscaled` ставит `src_valid_mark=1`; лечится `accept_local=1` на LAN-
  интерфейсах (см. раздел 2).
- **`wlan0` отсутствует при старте.** Драйвер `SKWIFI6621S` зондируется поздно;
  `pbr-wlan0` ждёт netdev до 30 с.
- **Hysteria один раз падает при загрузке** (`timeout: no recent network
  activity`) — сервер держит одну сессию на креды; `Restart=on-failure`
  поднимает клиента через 5 с.
- **`tproxy` в `inet`-таблице** требует стейтмента без `meta nfproto ipv4`,
  иначе nft ругается на конфликт семейств.
- **Нельзя `flush ruleset`**: tailscaled держит свои таблицы
  `ip/ip6 filter,nat,mangle`; конфиг пересоздаёт только `inet pbr_fw`, а
  drop-in убирает `flush` из stock-юнита.
- **Tailscale exit node трафик** приходит с `tailscale0`; интерфейс включён в
  `lan_ifaces`, иначе трафик шёл бы напрямую (YouTube резался бы DPI).

---

## 6. Безопасность

- Секреты (Wi-Fi пароль, Hysteria auth, Tailscale key) хранятся только в
  `.env` и сгенерированных `config/hostapd.conf` / `config/hysteria.yaml`;
  все три пути в `.gitignore`.
- В git попадают только `.env.example` и `*.template` с плейсхолдерами.
- Перед коммитом полезно прогнать:

  ```bash
  git log -p --all | grep -inE 'passphrase|password|auth:|tskey-|PRIVATE KEY'
  git status --short
  ```
