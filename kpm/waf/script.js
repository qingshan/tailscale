/*
 * Tailscale status/start/stop WAF. ES5 only.
 *
 * Commands are one-way LIPC strings: dev.qingshan.tsctl runCMD runs
 * `sh -c` (kindle.messaging has no synchronous result). waf-status.sh
 * writes status.json into this WAF directory; the page polls it.
 */

var TSCTL_ID = "dev.qingshan.tsctl";
var SCRIPTS_DIR = "/mnt/us/tailscale/scripts/";
var STATUS_CMD = "sh " + SCRIPTS_DIR + "waf-status.sh";
var START_CMD = "sh " + SCRIPTS_DIR + "start.sh";
var STOP_CMD = "sh " + SCRIPTS_DIR + "stop.sh";
var PRESS_FLASH_MS = 300;

var refreshTimer = null;

function flashPressed(el) {
    if (!el) {
        return;
    }
    var active = (" " + (el.className || "") + " ").indexOf(" primary ") >= 0;
    el.style.backgroundColor = active ? "#fff" : "#000";
    el.style.color = active ? "#000" : "#fff";
    setTimeout(function () {
        el.style.backgroundColor = "";
        el.style.color = "";
    }, PRESS_FLASH_MS);
}

function bindPress(el, fn) {
    if (!el) {
        return;
    }
    el.addEventListener("mousedown", function (ev) {
        if (ev.preventDefault) {
            ev.preventDefault();
        }
        flashPressed(el);
        setTimeout(fn, PRESS_FLASH_MS);
    });
}

function setDetails(text) {
    var el = byId("details");
    if (el) {
        el.innerHTML = text || "";
    }
}

function setUpdated(text) {
    var el = byId("updated");
    if (el) {
        el.innerHTML = text || "\u00a0";
    }
}

function setSummary(text) {
    var el = byId("summary");
    if (el) {
        el.innerHTML = text || "";
    }
}

function sendCmd(cmd) {
    if (sendStringCmd(TSCTL_ID, "runCMD", cmd)) {
        setError("");
        return true;
    }
    return false;
}

/* Ask status.sh to (re)write status.json, then read it back a bit later
   (tsctl runs the command asynchronously, so we can't read it right away). */
function refreshStatus(delayMs) {
    /* Only show the "Refreshing…" overlay until the first render lands;
       afterwards keep the last status visible while re-polling, so a
       healthy page doesn't keep flickering between "Refreshing…" and the
       real status every cycle. */
    var el = byId("details");
    if (!el || !el.innerHTML || el.innerHTML === "\u00a0") {
        setDetails("Refreshing\u2026");
    }
    sendCmd(STATUS_CMD);
    setTimeout(fetchStatusJson, delayMs || 1200);
}

function fetchStatusJson() {
    pollStatusJson(render, "status.json missing - is the tsctl runner running? Tap the Home screen icon to reopen the app (it restarts the runner).");
}

function render(data) {
    var backend = data.backendState || "Unknown";
    setError(data.error || "");

    if (!data.running) {
        if (data.error) {
            setState("Unavailable", "state-down");
            setSummary("Tailscale could not start on this Kindle.");
        } else {
            setState("Stopped", "state-down");
            setSummary("Tailscale is stopped on this Kindle. Start it to reconnect.");
        }
    } else if (backend === "NeedsLogin" || backend === "NeedsMachineAuth") {
        setState("Login required", "state-down");
        setSummary("Tailscale is running, but this Kindle needs to sign in again.");
    } else if (backend === "LoggedOut") {
        setState("Logged out", "state-down");
        setSummary("This Kindle is signed out of your tailnet.");
    } else if (backend === "Running") {
        setState("Connected", "state-up");
        setSummary("This Kindle is connected to your tailnet.");
    } else {
        setState("Starting…", "state-unknown");
        setSummary("Tailscale is running and checking its connection.");
    }

    setDetails(esc(backend));

    if (data.updatedAt) {
        var ageSec = Math.max(0, Math.round(new Date().getTime() / 1000 - data.updatedAt));
        setUpdated(ageSec + " seconds ago");
    } else {
        setUpdated("Waiting for first update");
    }
}

document.addEventListener("DOMContentLoaded", function () {
    hookChromeOnGo("dev.qingshan.tailscale", "tailscale");
    startAutoRefresh(function () {
        refreshStatus(1200);
    }, 6000);

    var btnStart = byId("btn-start");
    var btnStop = byId("btn-stop");
    var btnRefresh = byId("btn-refresh");
    if (btnStart) {
        bindPress(btnStart, function () {
            setState("Starting…", "state-unknown");
            setSummary("Starting Tailscale. This can take a few seconds.");
            sendCmd(START_CMD);
            setTimeout(function () {
                refreshStatus(1200);
            }, 8000);
        });
    }
    if (btnStop) {
        bindPress(btnStop, function () {
            setState("Stopping\u2026", "state-unknown");
            setSummary("Stopping Tailscale.");
            sendCmd(STOP_CMD);
            setTimeout(function () {
                refreshStatus(1200);
            }, 4000);
        });
    }
    if (btnRefresh) {
        bindPress(btnRefresh, function () {
            refreshStatus(1200);
        });
    }

    refreshStatus(800);
});
