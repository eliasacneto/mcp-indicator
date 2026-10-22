# MCP Indicator

Extensão do [GNOME Shell](https://www.gnome.org/) com um indicador na barra superior: quais servidores [MCP](https://modelcontextprotocol.io/) (Model Context Protocol) estão configurados e em execução neste computador.

Não é um MCP que controla o desktop. Só observa configs e processos.

![Menu do MCP Indicator](screenshot.png)

## O que aparece

- Ícone na barra; a lista fica no menu
- Estado por MCP: em execução (verde), degradado (amarelo), parado (cinza), remoto (azul)
- Degradado: porta TCP aberta mas handshake MCP falhou, ou unit/processo activo com a porta recusada
- Ações: reiniciar, parar, iniciar (só daemon HTTP/[systemd](https://systemd.io/)), logs (`journalctl --user`)
- stdio gerido pelo cliente ([Cursor](https://cursor.com/), [VS Code](https://code.visualstudio.com/), [Claude](https://claude.ai/), [OpenCode](https://opencode.ai/), etc.): a extensão não finge iniciar; o cliente é quem sobe o processo
- Notificação quando um MCP HTTP/systemd local passa de ok para degradado ou parado

## Como detecta

1. Lê JSON de config no home (`mcpServers`, `servers` ou `mcp`):
   - `~/.cursor/mcp.json`
   - `~/.claude.json`
   - `~/.config/Code/User/mcp.json`
   - `~/.config/opencode/opencode.json`
   - `~/.gemini/config/mcp_config.json`
   - `~/.copilot/mcp-config.json`
   - e outros listados em Preferências
2. Cruza com `/proc` (stdio: comando + args distintivos)
3. HTTP em localhost: TCP na porta e depois POST `initialize` ([JSON-RPC](https://www.jsonrpc.org/) MCP). HTTP 2xx–4xx (incluindo 406) conta como vivo. Remotos não são sondados, salvo se ligar isso nas preferências
4. Se existir unit systemd do utilizador com o mesmo nome (ex.: `ai-memory.service`), start/stop/restart e logs usam `systemctl --user` / `journalctl --user`

O mesmo servidor em vários clientes (ex.: `ai-memory` no Cursor e no Claude) aparece uma vez, com as origens juntas.

## Instalar

```bash
git clone https://github.com/rodriguesfas/mcp-indicator.git
cd mcp-indicator
./install.sh
```

A instalação cria um symlink em `~/.local/share/gnome-shell/extensions/mcp-indicator@rodriguesfas.github.io`.

- **X11:** Alt+F2, `r`, Enter, depois `gnome-extensions enable mcp-indicator@rodriguesfas.github.io`
- **Wayland:** logout/login e o mesmo `gnome-extensions enable`

[GNOME](https://www.gnome.org/) Shell 46–49.

## Pacote para [extensions.gnome.org](https://extensions.gnome.org/)

```bash
make shexli
```

Isto empacota o zip e corre o [Shexli](https://pypi.org/project/shexli/) (o analisador estático do EGO). Equivale a:

```bash
python3 -m venv venv
. venv/bin/activate
pip install -U -r requirements-shexli.txt
make pack
shexli mcp-indicator@rodriguesfas.github.io.shell-extension.zip
```

O ZIP não inclui `install.sh`, screenshot, Makefile nem o git. O screenshot sobe no formulário de [upload](https://extensions.gnome.org/upload/). O CI do GitHub corre o mesmo `make shexli`.

## Licença

[GPL-2.0-or-later](COPYING) (GNU General Public License, versão 2 ou posterior).

## Limites

- stdio só existe enquanto o cliente (Cursor, Claude, OpenCode) mantém o processo; play não aparece nesses
- casar processo é heurística; setups raros podem não bater
- HTTP remoto ([GitHub Copilot](https://github.com/features/copilot) etc.) entra como “remoto”, sem probe
- ações de parar/reiniciar só sinalizam os PIDs que a extensão já associou àquele MCP, excepto quando há unit systemd
