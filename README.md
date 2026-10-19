# NetOps with Kong AI Gateway and Cisco MCP servers

[![Kong AI Gateway](https://img.shields.io/badge/Kong_AI_Gateway-2.0.3-003459?style=flat&logo=kong&logoColor=white)](https://konghq.com/products/kong-ai-gateway)
[![Kong Konnect](https://img.shields.io/badge/Kong_Konnect-cloud-003459?style=flat&logo=kong&logoColor=white)](https://cloud.konghq.com)
[![Keycloak](https://img.shields.io/badge/Keycloak-26.4.5-4D4D4D?style=flat&logo=keycloak&logoColor=white)](https://www.keycloak.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1?style=flat&logo=postgresql&logoColor=white)](https://www.postgresql.org)
[![Docker Compose](https://img.shields.io/badge/Docker_Compose-2496ED?style=flat&logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![MCP](https://img.shields.io/badge/MCP-Model_Context_Protocol-000000?style=flat&logo=modelcontextprotocol&logoColor=white)](https://modelcontextprotocol.io)
[![pyATS](https://img.shields.io/badge/Cisco_pyATS-MCP_server-049FD9?style=flat&logo=cisco&logoColor=white)](https://github.com/ponchotitlan/pyATS_MCP)
[![Claude Code](https://img.shields.io/badge/Claude_Code-D97757?style=flat&logo=claude&logoColor=white)](https://claude.com/claude-code)
[![OpenID Connect](https://img.shields.io/badge/OpenID_Connect-F78C40?style=flat&logo=openid&logoColor=white)](https://openid.net/connect/)
[![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)

Puts the [pyATS MCP server](https://github.com/ponchotitlan/pyATS_MCP) behind
Kong AI Gateway. Keycloak decides who the caller is; the AI Gateway decides
which MCP tools they may see and call.

| Role (`mcp_role` claim) | Keycloak user        | Tools                                                                                                                              |
|-------------------------|----------------------|------------------------------------------------------------------------------------------------------------------------------------|
| `netops-viewer`         | `netops-viewer-user` | `pyats_list_devices`, `pyats_run_show_command`, `pyats_show_running_config`, `pyats_show_logging`, `pyats_ping_from_network_device` |
| `netops-admin`          | `netops-admin-user`  | all of the above, plus `pyats_configure_device`, `pyats_run_linux_command`, `pyats_run_dynamic_test`, `pyats_load_external_inventory` |

Both users' password is `kong`. No token gets a 401; a valid token without a
known `mcp_role` gets a 403.

## Architecture

```mermaid
flowchart LR
    subgraph clients["MCP clients"]
        cc["Claude Code<br/>(.mcp.json → pyats)"]
        cli["curl / CLI"]
    end

    subgraph konnect["Kong Konnect (cloud)"]
        cp["AI Gateway control plane<br/>ai-gateway-1<br/>auth strategy · AI Consumers · MCP server ACLs"]
    end

    subgraph docker["Docker network: kong-workshop"]
        dp["kong-ai-dp<br/>AI Gateway data plane<br/>:8010 /pyats-tools"]
        kc["keycloak<br/>realm: kong<br/>:8080"]
        pg[("postgres")]
        mcp["pyats-mcp<br/>:8000/mcp<br/>(not published)"]
    end

    devices["Network devices<br/>R1 · R2 · SW1 · SW2"]

    cc -- "Bearer JWT" --> dp
    cli -- "Bearer JWT" --> dp
    cc -. "get token" .-> kc
    cli -. "get token" .-> kc
    cp -- "config push (mTLS)" --> dp
    dp -- "discovery + JWKS" --> kc
    kc --- pg
    dp -- "allowed MCP calls" --> mcp
    mcp -- "SSH / CLI" --> devices
```

- **Konnect** holds the configuration: the `pyats-tools` MCP server, the
  `keycloak-kong` auth strategy, the AI Consumers and the access rules. It
  pushes them to the data plane.
- **`kong-ai-dp`** is the only way in. It validates every request's token,
  works out the caller's role and enforces the tool rules before anything
  reaches pyATS.
- **Keycloak** issues tokens with an `mcp_role` claim. Users and their roles
  live only here.
- **`pyats-mcp`** isn't published on the host, so it can't be called
  without going through Kong.

## Authentication and authorization flow

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant C as Claude Code / curl
    participant K as Keycloak (realm kong)
    participant G as kong-ai-dp (AI Gateway)
    participant P as pyats-mcp

    U->>C: ./keycloak/mcp-auth.sh login (username + password)
    C->>K: password grant (client mcp-client)
    K-->>C: access token + refresh token (claim mcp_role)

    C->>G: MCP request with header "Authorization: Bearer access-token"
    G->>K: discovery + signing keys (JWKS, cached)
    G->>G: verify signature, issuer, expiry
    alt token missing or invalid
        G-->>C: 401 Unauthorized
    end
    G->>G: mcp_role claim → AI Consumer (netops-admin / netops-viewer)
    alt no AI Consumer for that role
        G-->>C: 403 Forbidden
    end

    C->>G: tools/list
    G->>P: tools/list
    P-->>G: all 9 tools
    G-->>C: only the tools this consumer may use

    C->>G: tools/call pyats_configure_device
    alt consumer is netops-admin
        G->>P: tools/call
        P-->>G: result
        G-->>C: result
    else consumer is netops-viewer
        G-->>C: 403 Forbidden (never reaches pyATS)
    end
```

Every allow/deny decision is written to the AI Gateway's audit log.

## What's in here

| Path | Purpose |
|---|---|
| [docker-compose.yml](docker-compose.yml) | `kong-ai-dp`, `keycloak` + `postgres`, `pyats-mcp`; `vector`, `loki`, `grafana` in the `observability` profile |
| [konnect/create-ai-gateway.sh](konnect/create-ai-gateway.sh) | Creates the AI Gateway in Konnect, the data plane certificate and the `AI_*` values in `.env` |
| [konnect/create-mcp-acl.sh](konnect/create-mcp-acl.sh) | Creates the `pyats-tools` MCP server, the `keycloak-kong` auth strategy, the two AI Consumers and the access rules |
| [konnect/create-mcp-observability.sh](konnect/create-mcp-observability.sh) | Creates the `mcp-http-log` policy and attaches it to `pyats-tools` (`remove` undoes it) |
| [observability/](observability/) | Vector pipeline, Grafana data source and the MCP dashboard |
| [keycloak/setup.sh](keycloak/setup.sh) | Creates the `kong` realm, `mcp-client`, the `mcp_role` claim and the two users |
| [keycloak/mcp-auth.sh](keycloak/mcp-auth.sh) | `login` / `status` / `logout`, and the `headers` helper Claude Code runs |
| [keycloak/test-mcp-acl.sh](keycloak/test-mcp-acl.sh) | Checks the rules through Kong as each user |
| [.mcp.json](.mcp.json), [.claude/settings.json](.claude/settings.json) | The `pyats` server for Claude Code, pre-approved |

## Prerequisites

- Docker, `jq` and `curl`
- A Konnect account and a [Personal Access Token](https://cloud.konghq.com/global/account/tokens)
- The `pyats-mcp:latest` image, built from `../pyATS_MCP` with
  `docker compose build` there. It mounts `../pyATS_MCP/testbed.yaml`; set
  `PYATS_TESTBED_FILE` to use a different testbed.
- `cisco-ca.pem` in this directory: the corporate root CA that `kong-ai-dp`
  trusts for outbound HTTPS. It's git-ignored, so copy it in yourself. Off
  the corporate network, any valid PEM certificate will do.

## Step 1: Create the AI Gateway

1. Put your token in `.env` (see [.env.example](.env.example)):
   ```bash
   cp .env.example .env
   # edit .env: PAT=kpat_...
   ```
2. Create the AI Gateway and the data plane certificate:
   ```bash
   ./konnect/create-ai-gateway.sh
   ```
   `KONNECT_REGION` defaults to `eu`; set `us`, `au`, `in` or `me` to match
   the subdomain of your Konnect UI (`KONNECT_REGION=us ./konnect/create-ai-gateway.sh`).
   The script creates `ai-gateway-1` (or reuses it), generates
   `certs/kong-ai/tls.crt` / `tls.key`, registers the certificate, and writes
   `AI_GATEWAY_ID` and the `AI_KONNECT_*` endpoints into `.env`.
3. Start the containers:
   ```bash
   docker compose up -d
   ```
   If you previously `source`d `.env` in the same shell, `unset` the
   `AI_KONNECT_*` variables first: exported values win over `.env`, and the
   data plane would connect to the old cluster.
4. Check that the data plane registered:
   ```bash
   set -a; . ./.env; set +a
   curl -s https://eu.api.konghq.com/v1/ai-gateways/$AI_GATEWAY_ID/nodes \
     -H "Authorization: Bearer $PAT" | jq '.data[] | {hostname, version}'
   ```

| Port | Service |
|---|---|
| 8010 / 8453 | AI Gateway proxy (http / https) |
| 8110 | AI Gateway status |
| 8080 | Keycloak (admin / admin) |

## Step 2: Set up the Keycloak users

1. Wait for Keycloak to answer on `http://localhost:8080`, then:
   ```bash
   ./keycloak/setup.sh
   ```
   This creates the `kong` realm, the public `mcp-client` client (whose
   access tokens carry the `mcp_role` claim), and the two users. It's safe to
   re-run.
2. Check the users:
   - **Admin console:** open http://localhost:8080, log in as `admin` /
     `admin`, switch the realm dropdown from **master** to **kong**, then
     **Users**. A user's role is on its **Attributes** tab (`mcp_role`).
   - **CLI:**
     ```bash
     ADMIN=$(curl -s http://localhost:8080/realms/master/protocol/openid-connect/token \
       -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password | jq -r .access_token)
     curl -s "http://localhost:8080/admin/realms/kong/users?briefRepresentation=false" \
       -H "Authorization: Bearer $ADMIN" \
       | jq -r '.[] | [.username, (.attributes.mcp_role // ["-"])[0]] | @tsv'
     ```

To add a user, create them in the **kong** realm with an `mcp_role`
attribute of `netops-admin` or `netops-viewer`. Nothing changes in Kong.

## Step 3: Protect the MCP server

```bash
./konnect/create-mcp-acl.sh
```

This configures the AI Gateway in Konnect. It's safe to re-run, and resets
the access rules to the ones below.

1. **MCP server `pyats-tools`**, created if missing: a passthrough listener
   on `/pyats-tools` forwarding to `http://pyats-mcp:8000/mcp`.
2. **Auth strategy `keycloak-kong`** (`openid-connect`): validates the bearer
   token against `http://keycloak:8080/realms/kong` and maps its `mcp_role`
   claim to the AI Consumer with that name (`consumer_claims: [["mcp_role"]]`,
   `consumer_by: username`, `consumer_optional: false`). It also copies the
   token's `preferred_username` into an `X-Authenticated-User` header on every
   request it forwards to pyATS (`upstream_headers_claims` /
   `upstream_headers_names`), so the MCP server knows which user made each
   tool call, not just their role. Kong replaces any `X-Authenticated-User`
   header the client sends with the value from the token, so it can't be
   faked.
3. **AI Consumers `netops-admin` and `netops-viewer`**: one per role.
4. **Access rules on `pyats-tools`**:
   ```yaml
   access:
     auth_strategies: [keycloak-kong]
     acl_attribute_type: consumer
     acls:              { allow: [netops-admin, netops-viewer] }   # who may connect
     default_tool_acls: { allow: [netops-admin, netops-viewer] }   # tools without their own rule
   tools:                                                           # replace the default per tool
     - { name: pyats_configure_device,        access: { acls: { allow: [netops-admin] } } }
     - { name: pyats_run_linux_command,       access: { acls: { allow: [netops-admin] } } }
     - { name: pyats_run_dynamic_test,        access: { acls: { allow: [netops-admin] } } }
     - { name: pyats_load_external_inventory, access: { acls: { allow: [netops-admin] } } }
   ```

Then check all the cases at once:

```bash
./keycloak/test-mcp-acl.sh
```

Expected: no token → 401; the viewer sees 5 tools and gets 403 on
`pyats_configure_device`; the admin sees all 9.

### Where to find it in the Konnect UI

Under **AI Gateway → ai_gateway_1**:

| Object | Where |
|---|---|
| Auth strategy | **Auth Strategies → Keycloak (kong realm)** |
| Consumers | **Consumers** → `netops-admin`, `netops-viewer` |
| Access rules | **MCP servers → pyATS Tools** → **ACLs** (attribute type, **Default tool ACL**) and **Tools** |

`pyats-tools` is a passthrough listener, so Konnect never stores the pyATS
tool list: **Tools** shows only the four tools with their own rule, and every
other tool falls under the default tool ACL. Tool names aren't checked
against the server, so a typo silently leaves that tool open to viewers.

## Step 4a: Use it from the CLI

Every request needs `Authorization: Bearer <access token>`. MCP over HTTP is
a session: `initialize`, then `notifications/initialized`, then any number of
requests carrying the `Mcp-Session-Id` header the server returned.

1. Get a token for a user:
   ```bash
   TOKEN=$(curl -s http://localhost:8080/realms/kong/protocol/openid-connect/token \
     -d client_id=mcp-client -d grant_type=password \
     -d username=netops-viewer-user -d password=kong | jq -r .access_token)
   ```
   Or reuse your `mcp-auth.sh` login (see 4b):
   `TOKEN=$(./keycloak/mcp-auth.sh headers | jq -r .Authorization | cut -d' ' -f2)`
2. Open an MCP session through Kong:
   ```bash
   MCP=http://localhost:8010/pyats-tools
   H=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')

   SESSION=$(curl -s -D - -o /dev/null "${H[@]}" $MCP \
     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}' \
     | awk 'tolower($1)=="mcp-session-id:" {print $2}' | tr -d '\r')
   curl -s "${H[@]}" -H "Mcp-Session-Id: $SESSION" $MCP -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
   ```
3. List the tools this user may see:
   ```bash
   curl -s "${H[@]}" -H "Mcp-Session-Id: $SESSION" $MCP \
     -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
     | sed -n 's/^data: //p' | jq -r '.result.tools[].name'
   ```
4. Call an allowed tool:
   ```bash
   curl -s "${H[@]}" -H "Mcp-Session-Id: $SESSION" $MCP \
     -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"pyats_run_show_command","arguments":{"device_name":"R1","command":"show version"}}}' \
     | sed -n 's/^data: //p' | jq -r '.result.content[0].text | fromjson | .raw_output' | head -3
   ```
5. Try a config tool. As the viewer this prints `403` and the call never
   reaches pyATS. **As the admin it really applies the config**, creating
   `Loopback99` on R1:
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' "${H[@]}" -H "Mcp-Session-Id: $SESSION" $MCP \
     -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"pyats_configure_device","arguments":{"device_name":"R1","config_commands":"interface Loopback99"}}}'
   ```

The same commands work in bash and zsh. Repeat with
`username=netops-admin-user` to see all 9 tools.

## Step 4b: Use it from Claude Code

1. Log in once in a terminal, with any user from the **kong** realm:
   ```bash
   ./keycloak/mcp-auth.sh login     # prompts for username / password
   ./keycloak/mcp-auth.sh status    # Logged in as netops-viewer-user (mcp_role: netops-viewer)
   ```
2. Start `claude` in this directory (CLI or VS Code extension) and run
   `/mcp`. The `pyats` server shows as connected, with 5 tools for the viewer
   or 9 for the admin. [.claude/settings.json](.claude/settings.json)
   pre-approves it, so there's no approval prompt.
3. Ask something like *"List all interfaces of R1"*. As the viewer, a request
   to change config fails, because Claude Code never sees the config tools.
4. To switch user, run `login` again with the other user, then reconnect
   `pyats` from `/mcp`.
5. When you're done:
   ```bash
   ./keycloak/mcp-auth.sh logout    # revokes the session in Keycloak and deletes it locally
   ```

**How it works:** `login` exchanges your password for an offline refresh
token and stores only that token in `~/.config/pyats-mcp/session` (mode
600), never the password. The `pyats` entry in [.mcp.json](.mcp.json) runs
`./keycloak/mcp-auth.sh headers` as its `headersHelper` on every connect,
trading the stored token for a fresh access token. If a call gets a 401 or
403, Claude Code runs the helper again and retries once. Claude Code runs
the helper without a terminal, so it can't prompt you; that's why `login` is
a separate step.

**If `/mcp` shows the server as failed:**
- `./keycloak/mcp-auth.sh status` says "not logged in" or "session expired":
  run `login` again.
- The error mentions *Dynamic Client Registration*: Claude Code is using a
  server entry without the helper, so Kong answered 401 and Claude Code
  tried OAuth. Look for another entry pointing at the same URL with
  `claude mcp list`, and remove it.
- `claude mcp get pyats` says *Rejected*: remove `pyats` from
  `disabledMcpjsonServers` in your `.claude/settings.local.json`.

## Step 5 (optional): Observe MCP tool use in Grafana

The `observability` compose profile adds Vector, Loki and Grafana. An
`http-log` policy on `pyats-tools` makes the AI Gateway POST a log record
for every MCP request to Vector. Vector turns each record into one event per
JSON-RPC call and ships it to Loki, and Grafana shows them.

```mermaid
flowchart LR
    dp["kong-ai-dp<br/>policy mcp-http-log"] -- "http-log JSON" --> v["vector<br/>:9880/kong"]
    v -- "one event per MCP call" --> l[("loki")]
    l --> g["grafana<br/>:3000"]
```

1. Start the stack:
   ```bash
   docker compose --profile observability up -d
   ```
2. Create the `mcp-http-log` policy and attach it to `pyats-tools`:
   ```bash
   ./konnect/create-mcp-observability.sh
   ```
3. Use the MCP server (Claude Code, step 4a, or `./keycloak/test-mcp-acl.sh`),
   then open http://localhost:3000. The **MCP tool usage (Kong AI Gateway)**
   dashboard is the home page; anyone can view it, and `admin` / `admin`
   can edit.

Each event has:

| Field | Meaning |
|---|---|
| time | When Kong received the request |
| `user` | Keycloak `preferred_username` (the `X-Authenticated-User` header), `anonymous` without a token |
| `role` | AI Consumer, from `mcp_role` |
| `method`, `tool` | JSON-RPC method (`tools/call`, `tools/list`, ...) and tool name |
| `action` | `allow`, `deny` (blocked by a tool ACL, 403, never reaches pyATS) or `reject` (401, no valid token) |
| `status`, `latency_ms` | HTTP status Kong returned; time pyATS took to answer |
| `arguments`, `request` | Tool arguments; the inbound JSON-RPC request |
| `response`, `result` | The outbound JSON-RPC reply; the tool's text output |
| `is_error`, `error` | JSON-RPC error or `isError` in the tool result |

`job`, `method`, `tool`, `action`, `role` and `user` are Loki labels, the
rest is in the JSON line. For ad-hoc queries, use Grafana's **Explore** with
for example `{job="kong-mcp", method="tools/call", user="netops-viewer-user"} | json`.
Kong redacts the `Authorization` header before logging, so tokens are never
stored. A denied call has no request or reply in its event: Kong blocks it
before it reaches pyATS, and the AI Gateway logs only the decision and the
tool name.

The dashboard: totals (tool calls, denied, tool errors, active users, 401s),
calls over time by tool and by user, a who-called-what table, latency per
tool, a table of every call with its arguments and result, and a log panel
with each inbound request and outbound reply (expand a line for all fields).
Filter with the **User**, **Role**, **Tool** and **Decision** variables.

**If no events arrive:** `docker logs kong-ai-dp | grep http-log`. A
"connection refused" for `vector:9880` after recreating the `vector`
container means Kong still has its old IP address cached; restart
`kong-ai-dp` or wait for the DNS entry to expire. Konnect takes a few
seconds to push the policy to the data plane.

To stop sending logs, run `./konnect/create-mcp-observability.sh remove`,
then `docker compose --profile observability down` (add `-v` to delete the
stored events and Grafana's state).

## How the observability stack works

New to Vector and Loki? This section explains what each piece does, how
they connect, and where to look when you want to see what's going on.

### The short version

Think of a parcel service:

| Piece | Role in one line | Analogy |
|---|---|---|
| **Kong AI Gateway** | Writes a log record for every MCP request | The shop that hands over parcels |
| **Vector** | Receives the records, reshapes them, forwards them | The sorting center: opens, relabels, sends on |
| **Loki** | Stores the events and answers questions about them | The warehouse with an index |
| **Grafana** | Shows the events as dashboards and lets you search them | The front desk where you ask "where's my parcel?" |

Vector never keeps anything, Loki never draws anything, and Grafana never
stores anything. Each one does one job.

```mermaid
flowchart LR
    kong["🛡️ Kong AI Gateway<br/><i>writes a record per request</i>"]
    vector["🔀 Vector<br/><i>reshapes and forwards</i>"]
    loki[("🗄️ Loki<br/><i>stores and indexes</i>")]
    grafana["📊 Grafana<br/><i>shows and searches</i>"]
    you(["👤 You"])

    kong -- "HTTP POST<br/>raw JSON record" --> vector
    vector -- "HTTP push<br/>clean events" --> loki
    grafana -- "LogQL query" --> loki
    you -- "browser<br/>localhost:3000" --> grafana
```

### What happens when someone calls a tool

```mermaid
sequenceDiagram
    autonumber
    actor U as netops-viewer-user
    participant G as Kong AI Gateway
    participant P as pyats-mcp
    participant V as Vector
    participant L as Loki
    participant D as Grafana

    U->>G: tools/call pyats_run_show_command
    G->>P: forwards the call (ACL allows it)
    P-->>G: tool result
    G-->>U: tool result
    Note over G: After replying, Kong sends the log record<br/>in the background, so the user never waits for it
    G->>V: POST /kong with one JSON record
    V->>V: keep only what matters:<br/>who, tool, decision, request, reply
    V->>L: push the event
    D->>L: dashboard refreshes every 10 s
    L-->>D: matching events
```

### Vector: the sorting center

Vector is a small program that moves data from A to B and can change it on
the way. Every Vector config has the same three parts, and ours is
[observability/vector.yaml](observability/vector.yaml):

```mermaid
flowchart LR
    subgraph vector["Vector (observability/vector.yaml)"]
        direction LR
        src["📥 <b>source</b> kong<br/>listens on :9880/kong<br/>for Kong's JSON"]
        tr["⚙️ <b>transform</b> mcp_events<br/>small script that picks<br/>and renames fields"]
        sink["📤 <b>sink</b> loki<br/>pushes events to<br/>http://loki:3100"]
        src --> tr --> sink
    end
    kong["Kong"] --> src
    sink --> loki[("Loki")]
```

- **Source:** where data comes in. Here, an HTTP endpoint that Kong posts to.
- **Transform:** what happens to it. Kong's record is large and nested. The
  script, written in Vector's language VRL, pulls out the user, role, tool,
  decision, latency, request and reply. One Kong record can hold several MCP
  calls, so it can become several events.
- **Sink:** where data goes out. Here, Loki.

```mermaid
flowchart LR
    rec["<b>1 Kong record</b><br/>dozens of nested fields: headers,<br/>latencies, consumer, route, ai.mcp.rpc[ ], ai.mcp.audit[ ]"]
    rec --> e1["<b>event</b><br/>user: netops-viewer-user<br/>role: netops-viewer<br/>tool: pyats_run_show_command<br/>action: allow · status: 200<br/>request / response"]
    rec -. "if it held more<br/>MCP calls" .-> e2["<b>event</b><br/>..."]
```

### Loki: the warehouse

Loki is a database built for logs. Its main trick is that it splits every
event into two parts:

- **Labels**: a few short tags (`user`, `role`, `tool`, `action`, `method`,
  `job`). Loki indexes these, so filtering on them is fast. Think of them as
  the label on the outside of a box.
- **The log line**: the full JSON event, including the request and reply.
  It isn't indexed. Loki reads it only for the events the labels already
  matched. This is the contents of the box.

```mermaid
flowchart TB
    subgraph event["One stored event"]
        direction LR
        labels["🏷️ <b>Labels</b> (indexed, for filtering)<br/>job=kong-mcp<br/>user=netops-viewer-user<br/>role=netops-viewer<br/>tool=pyats_run_show_command<br/>action=allow · method=tools/call"]
        line["📄 <b>Log line</b> (the full JSON)<br/>status, latency_ms, arguments,<br/>request, response, result, error ..."]
    end
```

You ask Loki questions in **LogQL**. A query always starts with labels in
`{ }`, and can then dig into the JSON:

```mermaid
flowchart LR
    a["<b>{job=&quot;kong-mcp&quot;, user=&quot;netops-viewer-user&quot;}</b><br/>① pick boxes by their labels"]
    b["<b>| json</b><br/>② open the boxes:<br/>JSON fields become filterable"]
    c["<b>| status = &quot;403&quot;</b><br/>③ keep only what you want"]
    a --> b --> c
```

A few queries to try in Grafana's **Explore**:

| Question | LogQL |
|---|---|
| Everything one user did | `{job="kong-mcp", user="netops-viewer-user"}` |
| Every denied tool call | `{job="kong-mcp", action="deny"}` |
| Calls to one tool, with fields unpacked | `{job="kong-mcp", tool="pyats_run_show_command"} \| json` |
| Calls slower than 5 seconds | `{job="kong-mcp", method="tools/call"} \| json \| latency_ms > 5000` |
| Tool calls per user in the last hour | `sum by (user) (count_over_time({job="kong-mcp", method="tools/call"}[1h]))` |

### Grafana: the front desk

Grafana is the only one with a web UI: http://localhost:3000 (`admin` /
`admin`, or just view without logging in). Two places matter:

- **Dashboards → Kong AI Gateway → MCP tool usage**: the ready-made view.
  Every panel is a saved LogQL query. Open a panel's menu → **Edit** to see
  its query.
- **Explore** (compass icon in the left menu) → data source **Loki**:
  write your own queries. Click an event to see all its fields.

Grafana's settings come from files, so nothing is clicked together by hand:

```mermaid
flowchart LR
    ds["observability/grafana/provisioning/<br/>datasources/loki.yaml"] -- "adds the Loki<br/>data source" --> gf["Grafana"]
    prov["observability/grafana/provisioning/<br/>dashboards/dashboards.yaml"] -- "says where<br/>dashboards live" --> gf
    dash["observability/grafana/dashboards/<br/>mcp-tools.json"] -- "the dashboard" --> gf
```

### Where to look

Vector and Loki have no web UI. You see their configs as files and their
state through logs or HTTP endpoints. Loki's port isn't published to your
laptop, so reach it from a container on the Docker network.

| I want to... | Do this |
|---|---|
| See Vector's config | Open [observability/vector.yaml](observability/vector.yaml) |
| Check Vector is receiving and forwarding | `docker logs vector` (it only prints problems) |
| Check Kong is sending | `docker logs kong-ai-dp \| grep http-log` (no output means no errors) |
| See Loki's config file | `docker exec loki cat /etc/loki/local-config.yaml` |
| See Loki's full config, defaults included | `docker run --rm --network kong-workshop curlimages/curl -s http://loki:3100/config` |
| Check Loki is up | same command with `http://loki:3100/ready` |
| List the labels Loki knows | same command with `http://loki:3100/loki/api/v1/labels` |
| Browse and search the events | Grafana → **Explore** → **Loki** |
| See how a dashboard panel is built | Grafana → panel menu → **Edit** |

## Keycloak issuer note

`KC_HOSTNAME=http://localhost:8080` pins the token issuer to the host-facing
URL, so a token fetched from the laptop validates in Kong, which reaches
Keycloak as `keycloak:8080`. `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` keeps
`jwks_uri` / `token_endpoint` on whatever host was used:

```bash
docker run --rm --network kong-workshop curlimages/curl -s \
  http://keycloak:8080/realms/kong/.well-known/openid-configuration | jq '{issuer, jwks_uri}'
# issuer   => http://localhost:8080/realms/kong
# jwks_uri => http://keycloak:8080/realms/kong/protocol/openid-connect/certs
```

## Why consumers instead of matching the claim directly

The MCP server can match rules against a token claim directly
(`acl_attribute_type: oauth_access_token`). With this setup the gateway
rejected that with "access token claims not available"; it seems to need
the `access.metadata` OAuth setup. Mapping `mcp_role` to one AI Consumer per
role keeps Keycloak as the only place that assigns roles, with just two
objects in Kong. The trade-off: Konnect's analytics and logs show the role,
not the individual user. The user still reaches pyATS in the
`X-Authenticated-User` header (see step 3).

## Debugging pyats-mcp directly

`pyats-mcp` isn't published on the host. Call it from a container on the
same network:

```bash
docker run --rm --network kong-workshop curlimages/curl -s -X POST \
  http://pyats-mcp:8000/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

## Undo / tear down

```bash
docker compose --profile observability down   # add -v to also delete Keycloak's database and the stored events
```

To remove the access control in Konnect, drop the `access` block and tools
from `pyats-tools` (UI or a PUT), then delete the `keycloak-kong` auth
strategy and the two AI Consumers.
