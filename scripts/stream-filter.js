const fs = require("fs");
const readline = require("readline");

let sessionId = "";
let modelId = "";
let failed = false;
let finalText = "";

function oneLine(value, max = 120) {
  const text = String(value == null ? "" : value).replace(/\s+/g, " ").trim();
  return text.length > max ? text.slice(0, max) + "..." : text;
}

function emit(text) {
  if (text) console.log(text);
}

function shellDetails(text) {
  try {
    const details = JSON.parse(text);
    return {
      target: details.command || "",
      exitCode: details.exit_code,
      failure: String(details.output || details.terminal_status || ""),
    };
  } catch (_) {
    return { target: "", exitCode: undefined, failure: "" };
  }
}

function render(record) {
  if (!record || typeof record !== "object") return;
  if (record.stream && record.stream.kind === "session" && record.stream.id) {
    sessionId = String(record.stream.id);
  }
  const payload = record.payload && typeof record.payload === "object" ? record.payload : {};
  if (typeof record.payload_type === "string" && record.payload_type.startsWith("run.terminal.") &&
      record.payload_type !== "run.terminal.completed") {
    failed = true;
    emit(oneLine(payload.reason || payload.text, 400));
    return;
  }
  switch (record.payload_type) {
    case "run.model.configured":
      modelId = String(payload.model_id || "");
      break;
    case "run.output.delta":
      break;
    case "run.terminal.completed":
      if (payload.terminal === "completed") {
        finalText = String(payload.text || "");
      } else {
        failed = true;
        emit(oneLine(payload.reason || payload.text, 400));
      }
      break;
    case "task.lifecycle.proposed":
      break;
    case "task.lifecycle.status": {
      const message = String((payload.event || {}).message || "");
      const attempt = message.match(/attempt\s+(\d+)\s*\//i);
      if (attempt && Number(attempt[1]) > 1) emit("  ~ " + oneLine(message, 220));
      break;
    }
    case "tool.result": {
      const edit = payload.edit_facts || {};
      const correlation = payload.correlation_facts || {};
      const tool = String(edit.tool_name || correlation.tool_name || "tool");
      let target = edit.path || payload.path || "";
      const text = String(payload.text || "");
      const shell = /shell|powershell/i.test(tool) ? shellDetails(text) : null;
      if (shell && shell.target) target = shell.target;
      emit("  > " + oneLine(tool, 80) + " " + oneLine(target, 120));

      let failure = text;
      let exitCode;
      if (shell) {
        exitCode = shell.exitCode;
        failure = shell.failure;
      }
      if (correlation.outcome === "failure" || (exitCode !== undefined && Number(exitCode) !== 0)) {
        const firstLine = oneLine(String(failure || "").split(/\r?\n/)[0] || (exitCode !== undefined ? "exit " + exitCode : "failed"), 220);
        emit("  x " + oneLine(tool, 80) + ": " + firstLine);
      }
      break;
    }
    case "task.lifecycle.failed": {
      const reason = String((payload.event || {}).reason || payload.reason || "");
      emit(oneLine(reason, 400));
      break;
    }
    default:
      break;
  }
}

function writeMeta() {
  const metaPath = process.env.MUSE_RESCUE_META_FILE;
  if (metaPath) {
    fs.writeFileSync(metaPath, JSON.stringify({ sessionId, modelId, failed }) + "\n");
  }
  if (finalText) emit(finalText);
}

readline.createInterface({ input: process.stdin })
  .on("line", (line) => {
    let record;
    try {
      record = JSON.parse(line);
    } catch (_) {
      // Ignore malformed and non-JSON lines; Muse's --json output is JSONL.
      return;
    }
    render(record);
  })
  .on("close", writeMeta);
