#!/usr/bin/python3
# Общая часть gp-vpn: работа с официальным CLI GlobalProtect от служебной учётки gpvpn.
# Используют панель в трее (gp-vpn-tray, как модуль) и расширение GNOME Shell (как программа):
#   gpvpn.py status              -> JSON: состояние, гейт, IP, время, гейты, портал
#   gpvpn.py run <команда…>      -> JSON: rc, вывод, ошибка — команда без диалога
#   gpvpn.py session <команда…>  диалог в псевдотерминале. stdin: первая строка — JSON
#       {"login", "password", "gateway", "yes"} (секреты только так), дальше — ответы
#       {"answer": "…"} или {"cancel": true}. stdout: JSON-строки
#       {"event": "prompt", "kind": "text|secret|choice|confirm", "text", "options"} и в конце
#       {"event": "done", "rc", "error", "output"}. Логин, пароль и нужный гейт подставляются сами.
import json, os, pty, re, select, shlex, signal, subprocess, sys, termios, time

GP = shlex.split(os.environ.get("GP_VPN_GP", "sudo -n -u gpvpn /usr/libexec/gp-vpn/gp"))  # GP_VPN_GP — для проверок
PORTAL_FILE = os.environ.get("GP_VPN_PORTAL_FILE", "/var/lib/gpvpn/portal")  # последний портал, его пишет gp
PROMPTS = {  # частые запросы CLI — по-русски (оригинал остаётся в скобках)
    "passcode": "Введите одноразовый код",
    "otp": "Введите одноразовый код",
    "token": "Введите код с токена",
    "reason": "Укажите причину отключения",
    "ticket": "Укажите номер заявки",
}
KNOWN_ERRORS = {  # частые ответы портала/шлюза — по-человечески
    "user authentication failed": "Портал отклонил логин или пароль. Проверьте раскладку клавиатуры и Caps Lock.",
    "auth-failed": "Портал отклонил логин или пароль. Проверьте раскладку клавиатуры и Caps Lock.",
    "cannot connect to globalprotect portal": "Портал не отвечает — проверьте адрес и интернет.",
    "invalid portal": "Неверный адрес портала.",
    "cannot connect to local gpd service": "Не запущена служба GlobalProtect (gpd / gp-vpn-agent).",
    "занят другой командой": "GlobalProtect занят другой командой — попробуйте ещё раз.",
}


def clean(text):
    # CLI рисует индикатор «\r<пробелы>\r» и пишет \r\n — оставляем обычные строки
    return "\n".join(raw.split("\r")[-1].rstrip() for raw in text.replace("\r\n", "\n").split("\n"))


def gp(*args, timeout=30):
    # Одна команда CLI без диалога
    try:
        p = subprocess.run(GP + list(args), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
        return p.returncode, clean(p.stdout + p.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


def parse_status(out):
    m = re.search(r"GlobalProtect status:\s*(.+)", out)
    if not m:
        return None
    s = m.group(1).strip().lower()
    if "internal" in s:
        return "internal"
    if s.startswith("connected"):
        return "on"
    if s.startswith("disconnecting"):
        return "disconnecting"
    if s.startswith(("connecting", "discover", "retriev", "authent")):
        return "connecting"
    return "off"


def parse_fields(out):
    return {k.strip(): v.strip() for k, v in (l.split(":", 1) for l in out.splitlines() if ":" in l)}


def parse_gateways(out):
    # Таблица «Name  Address  Preferred» из show --manual-gateway -> [(имя, адрес, предпочтён)]
    rows, table = [], False
    for l in out.splitlines():
        if l.startswith("---"):
            table = True
        elif table and l.strip():
            # колонки бывают слиты одним пробелом: справа «yes/no», перед ним адрес (без пробелов), слева имя
            words = l.split()
            pref = words[-1].lower() in ("yes", "true") if words[-1].lower() in ("yes", "no", "true", "false") else None
            if pref is not None:
                words = words[:-1]
            addr = words.pop() if len(words) > 1 else ""
            rows.append((" ".join(words), addr, bool(pref)))
    return rows


def friendly(out):
    low = out.lower()
    for key, msg in KNOWN_ERRORS.items():
        if key in low:
            return msg
    lines = [l.strip() for l in out.splitlines() if re.search(r"error|fail|unable|cannot|invalid|denied", l, re.I)]
    return lines[-1][:300] if lines else ""


def portal():
    try:
        with open(PORTAL_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


def status(details=True):
    rc, out = gp("show", "--status")
    st = parse_status(out) if rc == 0 else None
    res = {"state": st, "details": {}, "gateways": [], "portal": portal()}
    if st and details:
        if st in ("on", "internal"):
            res["details"] = parse_fields(gp("show", "--details")[1])
        res["gateways"] = parse_gateways(gp("show", "--manual-gateway")[1])
    return res


def classify(line, before, creds, used, cancelling):
    """Что делать с запросом CLI: ("send", ответ) — ответить самим, ("ask", вид, текст, варианты) — спросить."""
    low = line.lower()
    if cancelling and "(y/n)" in low:
        return ("send", "y")
    if re.fullmatch(r"(?i)username(\(.*\))?:", line):
        if "user" not in used and creds.get("login") is not None:
            used.add("user")
            return ("send", creds["login"])
        return ("ask", "text", "\n".join(before[-1:] + [line]), [])
    if re.search(r"(?i)password[^:]*:$", line) and "pem" not in low:
        if "pw" not in used and creds.get("password"):
            used.add("pw")
            return ("send", creds["password"])
        return ("ask", "secret", "Пароль" + (" (прошлый не подошёл)" if "pw" in used else "") + ":", [])
    if "pem pass phrase" in low:
        return ("ask", "secret", "Пароль от сертификата клиента:", [])
    m = re.search(r"(?i)choose (.+?) from the list above\(1-(\d+)\):$", line)
    if m:
        opts = [list(mm.groups()) for l in before for mm in [re.match(r"^\s*(\d+)[.):]?\s+(.+)$", l)] if mm]
        what = m.group(1).lower()
        target = creds.get("gateway")
        if target and "gateway" in what:
            hit = next((n for n, text in opts if target.lower() in text.lower()), None)
            if hit:
                return ("send", hit)
        what = "гейт" if "gateway" in what else "сертификат" if "cert" in what else m.group(1)
        return ("ask", "choice", f"Выберите {what}:", opts)
    if re.search(r"\(y/n\)\??$", low):
        if creds.get("yes"):
            return ("send", "y")
        return ("ask", "confirm", "\n".join(before[-4:] + [line]), [])
    # Остальное — код (OTP/passcode), причина отключения и т. п.: спрашиваем как есть
    secret = bool(re.search(r"pass|pin|token|otp|code|код", low))
    ru = next((v for k, v in PROMPTS.items() if k in low), None)
    return ("ask", "secret" if secret else "text", "\n".join(before[-2:] + [f"{ru} ({line.rstrip(':')}):" if ru else line]), [])


def session(args):
    emit = lambda **e: (sys.stdout.write(json.dumps(e, ensure_ascii=False) + "\n"), sys.stdout.flush())
    creds = json.loads(sys.stdin.readline() or "{}")
    used, cancelling, out, mark, asked = set(), False, "", 0, -1
    pid, fd = pty.fork()
    if pid == 0:
        try:
            a = termios.tcgetattr(0)
            a[3] &= ~termios.ECHO  # ответы (и пароль) не попадают в вывод
            termios.tcsetattr(0, termios.TCSANOW, a)
            os.execvp(GP[0], GP + args)
        finally:
            os._exit(127)

    def send(text):
        nonlocal out, mark
        try:
            os.write(fd, (text + "\n").encode())
        except OSError:
            pass
        out += "\n"
        mark = len(clean(out))

    inputs, quiet_since = [fd, sys.stdin.fileno()], None
    while True:
        r, _, _ = select.select(inputs, [], [], 0.1)
        if fd in r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                data = b""
            if not data:
                break
            out += data.decode(errors="replace")
            quiet_since = time.monotonic()
        if sys.stdin.fileno() in r:
            line = sys.stdin.readline()
            if not line:  # клиент ушёл — отменяем
                inputs.remove(sys.stdin.fileno())
                line = '{"cancel": true}'
            msg = json.loads(line or "{}")
            if msg.get("cancel"):
                cancelling = True
                try:
                    os.write(fd, b"\x03")  # Ctrl-C; на «Want to cancel current command?» ответим «y»
                except OSError:
                    pass
                signal.signal(signal.SIGALRM, lambda *a: os.kill(pid, signal.SIGTERM))
                signal.alarm(6)
            elif "answer" in msg:
                send(str(msg["answer"]))
        # Запрос — строка без перевода строки, после которой CLI замолчал
        if quiet_since and time.monotonic() - quiet_since > 0.35:
            quiet_since = None
            text = clean(out)
            lines = text[mark:].split("\n")
            if lines[-1].strip() and len(text) != asked:
                asked = len(text)
                what = classify(lines[-1].strip(), [l for l in lines[:-1] if l.strip()], creds, used, cancelling)
                if what[0] == "send":
                    send(what[1])
                else:
                    emit(event="prompt", kind=what[1], text=what[2], options=what[3])
    try:
        _, st = os.waitpid(pid, 0)
        rc = os.waitstatus_to_exitcode(st)
    except ChildProcessError:
        rc = 1
    output = clean(out).strip()
    emit(event="done", rc=rc, cancelled=cancelling, error=friendly(output), output=output)


if __name__ == "__main__":
    cmd, rest = (sys.argv[1] if len(sys.argv) > 1 else ""), sys.argv[2:]
    if cmd == "status":
        print(json.dumps(status(), ensure_ascii=False))
    elif cmd == "run":
        rc, out = gp(*rest)
        print(json.dumps({"rc": rc, "output": out, "error": friendly(out) if rc else ""}, ensure_ascii=False))
    elif cmd == "session":
        session(rest)
    else:
        sys.exit("Использование: gpvpn.py status | run <команда…> | session <команда…>")
