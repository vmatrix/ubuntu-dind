# dnsmasq Compose test

This example verifies Docker-in-Docker bridge networking, static container IPs,
Docker Compose, and a local dnsmasq resolver inside the DinD daemon.

It intentionally uses `172.31.0.0/16` instead of `172.20.0.0/16` because many
EKS clusters use `172.20.0.10` as the Kubernetes DNS service IP.

Run inside the ubuntu-dind container:

```bash
cd /ubuntu-dind/examples/dnsmasq-compose
docker compose up -d
docker exec my_web_app nslookup my-web-app.local
docker exec my_web_app wget -qO- http://my-web-app.local | head
```

Stop it with:

```bash
docker compose down
```
