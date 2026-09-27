/* Run with Node: exercises the shipped ES5 WAF without a Kindle. */
var assert = require("assert");
var fs = require("fs");
var vm = require("vm");
var markup = fs.readFileSync("kpm/waf/index.html", "utf8");
var elements = {}, timers = [], sent = [], domReady;
function makeElement(id) {
    var el = { id:id, className:"", innerHTML:"", style:{}, listeners:{},
        addEventListener:function (kind, fn) { this.listeners[kind] = fn; } };
    elements[id] = el;
}
markup.replace(/\bid="([^"]+)"/g, function (_, id) { makeElement(id); });
var document = { addEventListener:function (kind, fn) { if (kind === "DOMContentLoaded") { domReady = fn; } } };
var context = { document:document, Date:Date, byId:function (id) { return elements[id]; },
    setTimeout:function (fn) { timers.push(fn); return timers.length; },
    sendStringCmd:function (_, __, cmd) { sent.push(cmd); return true; },
    pollStatusJson:function () {}, startAutoRefresh:function () {}, hookChromeOnGo:function () {} };
var stubs = Object.assign({}, context);
vm.createContext(context);
vm.runInContext(fs.readFileSync("common/waf-base.js", "utf8"), context);
Object.assign(context, stubs);
vm.runInContext(fs.readFileSync("kpm/waf/script.js", "utf8"), context);
assert(domReady, "WAF must register its startup handler");
domReady();
assert(sent.every(function (cmd) { return /waf-status\.sh$/.test(cmd); }), "Opening the app must only request status");
function flush() { while (timers.length) { timers.shift()(); } }
function press(id) { var ev = { preventDefault:function () { this.prevented = true; } }; elements[id].listeners.mousedown(ev); assert(ev.prevented); flush(); }
context.render({ running:false, backendState:"Stopped", updatedAt:Math.round(new Date().getTime() / 1000), error:"" });
assert.equal(elements.state.innerHTML, "Stopped");
assert.equal(elements.error.innerHTML, "");
context.render({ running:false, backendState:"Start failed", error:"tailscaled failed <log>" });
assert.equal(elements.state.innerHTML, "Unavailable");
assert.equal(elements.error.innerHTML, "tailscaled failed &lt;log&gt;");
context.render({ running:true, backendState:"Running", updatedAt:Math.round(new Date().getTime() / 1000) });
assert.equal(elements.state.innerHTML, "Connected");
assert.equal(elements.state.className, "state state-up");
assert.equal(elements.details.innerHTML, "Running");
assert(elements.updated.innerHTML.indexOf("seconds ago") >= 0);
context.render({ running:true, backendState:"NeedsLogin" });
assert.equal(elements.state.innerHTML, "Login required");
context.render({ running:true, backendState:"NeedsMachineAuth" });
assert.equal(elements.state.innerHTML, "Login required");
context.render({ running:true, backendState:"LoggedOut" });
assert.equal(elements.state.innerHTML, "Logged out");
context.render({ running:true, backendState:"Starting" });
assert.equal(elements.state.innerHTML, "Starting…");
assert(sent.every(function (cmd) { return /waf-status\.sh$/.test(cmd); }), "Status renders must not start or stop Tailscale");
var before = sent.length;
press("btn-refresh");
assert(sent.slice(before).some(function (cmd) { return /waf-status\.sh$/.test(cmd); }));
assert(sent.slice(before).every(function (cmd) { return /waf-status\.sh$/.test(cmd); }));
press("btn-start");
assert(sent.some(function (cmd) { return /start\.sh$/.test(cmd); }));
assert.equal(elements.state.innerHTML, "Starting…");
press("btn-stop");
assert(sent.some(function (cmd) { return /stop\.sh$/.test(cmd); }));
assert.equal(elements.state.innerHTML, "Stopping…");
console.log("Tailscale WAF E2E: status, login, refresh, start, and stop OK");
