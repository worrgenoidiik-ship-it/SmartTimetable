#!/bin/sh
# Installs or updates the keeper on the VPS. Run on the Mac:
#   sh deploy.sh
# Everything goes through ONE ssh connection (the route to the VPS sometimes drops new SSH
# connections before the greeting), retried up to 8 times. The secret key is created on the
# server once and copied to the Mac clipboard (never printed) for the app on the iPhone.
# The server address is not in git: put "root@IP" into Server/host.txt or set KEEPER_HOST.
HOST=${KEEPER_HOST:-$(cat "$(dirname "$0")/../host.txt" 2>/dev/null)}
[ -n "$HOST" ] || { echo "Укажите сервер: echo root@IP > Server/host.txt" >&2; exit 1; }
PORT=${KEEPER_SSH_PORT:-$(cat "$(dirname "$0")/../ssh_port.txt" 2>/dev/null || echo 22)}
DIR=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=$(mktemp)
OUT=$(mktemp)
trap 'rm -f "$PAYLOAD" "$OUT"' EXIT

KEEPER_B64=$(base64 < "$DIR/keeper.py" | tr -d '\n')
UNIT_B64=$(base64 < "$DIR/smarttable-keeper.service" | tr -d '\n')
cat > "$PAYLOAD" <<EOF
set -e
mkdir -p /opt/smarttable-keeper
install -d -m 700 /etc/smarttable-keeper
echo '$KEEPER_B64' | base64 -d > /opt/smarttable-keeper/keeper.py
chmod 755 /opt/smarttable-keeper/keeper.py
echo '$UNIT_B64' | base64 -d > /etc/systemd/system/smarttable-keeper.service
if [ ! -s /etc/smarttable-keeper/secret ]; then
  python3 -c "import secrets; print(secrets.token_urlsafe(24))" > /etc/smarttable-keeper/secret
  chmod 600 /etc/smarttable-keeper/secret
fi
systemctl daemon-reload
systemctl enable smarttable-keeper >/dev/null 2>&1
systemctl restart smarttable-keeper
sleep 2
systemctl is-active smarttable-keeper >&2
journalctl -u smarttable-keeper -n 3 --no-pager -o cat >&2
printf 'SECRET:%s\n' "\$(cat /etc/smarttable-keeper/secret)"
EOF

i=1
while [ $i -le 8 ]; do
  if ssh -o ConnectTimeout=15 -p "$PORT" "$HOST" 'sh -s' < "$PAYLOAD" > "$OUT"; then
    SECRET=$(sed -n 's/^SECRET://p' "$OUT")
    if [ -n "$SECRET" ]; then
      printf '%s' "$SECRET" | pbcopy
      echo "Готово. Ключ скопирован в буфер обмена Мака: вставь его в приложении (Настройки → Сервер-пингер)."
      exit 0
    fi
    echo "Сервер ответил, но ключ не получен." >&2
    exit 1
  fi
  echo "Попытка $i не удалась, пробую ещё раз через 5 секунд…" >&2
  i=$((i + 1))
  sleep 5
done
echo "Не удалось подключиться к серверу за 8 попыток." >&2
exit 1
