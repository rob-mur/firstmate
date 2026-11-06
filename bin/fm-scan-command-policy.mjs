#!/usr/bin/env node
// Semantic policy for the scan-guard: is a shell command a whole-filesystem
// scan - a recursive grep, find, or recursive searcher rooted at /, ~, $HOME or
// a user's home directory?
//
// Such a scan walks every project clone, worktree, node_modules, and cache on
// the machine. In the recorded primary session five of them ran into the 120 s
// tool timeout and returned nothing, while the answer sat in a durable record
// firstmate already keeps. This policy blocks exactly that shape and names the
// record to read instead; a search rooted inside a repo or a directory is never
// touched. The environmental scoping to the real primary checkout lives in the
// bin/fm-scan-pretool-check.sh transport. See docs/scan-guard.md.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification. This policy never evaluates, expands, sources, or runs any
// byte of the submitted command. Its threat model is agent mistakes, so
// malformed syntax, `bash -c` payloads, and xargs/subshell indirection are out
// of scope and allowed.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";

const REASON =
  "a whole-filesystem scan (recursive grep or find rooted at /, ~ or a home directory) is blocked in the primary firstmate session: it walks every clone and cache on the machine and times out. Read the durable record instead - data/projects.md for which clones exist and where, data/backlog.md or bin/fm-crew-state.sh for work and its state, state/<id>.status and data/<id>/report.md for a task's events and findings, data/learnings.md and data/captain.md for notes and preferences - or scope the search to one directory, such as grep -r <pattern> projects/<clone>.";

const GREP_COMMANDS = new Set(["grep", "egrep", "fgrep", "rgrep"]);
// Recursive by default; the first operand is the pattern unless -e/-f gives it.
const RECURSIVE_SEARCHERS = new Set(["rg", "ag", "ack"]);
// Options whose value is the next word, so it is never mistaken for an operand.
const GREP_VALUE_OPTIONS = new Set([
  "-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D",
  "--include", "--exclude", "--exclude-dir", "--max-count", "--file", "--regexp", "--directories", "--devices",
  "--after-context", "--before-context", "--context", "--label",
]);
// rg/ag/ack: -r is a replacement value and -E an encoding value there, unlike grep.
const SEARCHER_VALUE_OPTIONS = new Set([
  "-e", "-f", "-m", "-A", "-B", "-C", "-g", "-t", "-T", "-j", "-M", "-E", "-r",
  "--max-depth", "--glob", "--type", "--type-not", "--max-count", "--file", "--regexp", "--ignore-dir",
]);
const PATTERN_OPTIONS = new Set(["-e", "-f", "--regexp", "--file"]);
// A bounded find that cannot recurse far is a directory listing, not a scan.
const SHALLOW_DEPTH = 2;

function homeDirectories() {
  const homes = new Set();
  for (const candidate of [process.env.HOME, safeHomedir()]) {
    if (candidate) homes.add(normalizePath(candidate));
  }
  return homes;
}

function safeHomedir() {
  try {
    return homedir();
  } catch {
    return "";
  }
}

// Collapse repeated slashes and drop a trailing /, /., or /* so that `/`, `//`,
// `/.`, `/*`, `~/`, and `$HOME/*` all reduce to their root spelling.
function normalizePath(value) {
  let path = value.replace(/\/{2,}/g, "/");
  for (;;) {
    const next = path.replace(/\/(?:\.|\*)$/, "").replace(/(.)\/$/, "$1");
    if (next === path) break;
    path = next;
  }
  return path === "" ? "/" : path;
}

function isBroadRoot(word, homes) {
  if (!word) return false;
  const value = normalizePath(word.value);
  if (value === "/" || value === "~" || value === "$HOME" || value === "${HOME}") return true;
  if (!word.literal && !value.startsWith("$HOME") && !value.startsWith("${HOME}")) return false;
  if (value === "/home" || value === "/Users" || /^\/(?:home|Users)\/[^/]+$/.test(value)) return true;
  return homes.has(value);
}

function isShortRecursiveCluster(value) {
  return /^-[A-Za-z0-9]+$/.test(value) && /[rR]/.test(value);
}

// Split the words after the command into option words and operands, consuming
// the value of value-taking options and recording whether -e/-f named the pattern.
function parseOperands(args, valueOptions) {
  const operands = [];
  const options = [];
  let patternGiven = false;
  let endOfOptions = false;
  for (let i = 0; i < args.length; i += 1) {
    const value = args[i].value;
    if (!endOfOptions && value === "--") {
      endOfOptions = true;
      continue;
    }
    if (!endOfOptions && value.startsWith("-") && value.length > 1) {
      options.push(value);
      const name = value.startsWith("--") ? value.split("=")[0] : value.slice(0, 2);
      if (PATTERN_OPTIONS.has(name)) patternGiven = true;
      // A value-taking option given as a bare flag takes the next word; one given
      // as --opt=value or -Xvalue already carries its value.
      if (valueOptions.has(value)) i += 1;
      continue;
    }
    operands.push(args[i]);
  }
  return { operands, options, patternGiven };
}

function grepRecursive(command, options, args) {
  if (basename(command.value) === "rgrep") return true;
  if (options.some((option) => option === "--recursive" || option === "--dereference-recursive" || option === "--directories=recurse" || isShortRecursiveCluster(option))) return true;
  // `-d recurse` / `-drecurse` spelled with a separate value.
  return args.some((word, i) => (word.value === "-d" || word.value === "--directories") && args[i + 1]?.value === "recurse");
}

function findRoots(args) {
  const roots = [];
  let i = 0;
  while (i < args.length && /^-(?:H|L|P|O\d?|D)$/.test(args[i].value)) i += args[i].value === "-D" ? 2 : 1;
  for (; i < args.length; i += 1) {
    const value = args[i].value;
    if (value.startsWith("-") || value === "(" || value === "!" || value === ")") break;
    roots.push(args[i]);
  }
  return { roots, expression: args.slice(i) };
}

function findIsShallow(expression) {
  for (let i = 0; i < expression.length - 1; i += 1) {
    if (expression[i].value === "-maxdepth" && /^\d+$/.test(expression[i + 1].value)) {
      return Number(expression[i + 1].value) <= SHALLOW_DEPTH;
    }
  }
  return false;
}

function scansBroadly(position, homes) {
  const command = position.command;
  if (!command || position.unresolvedWrapperOption) return false;
  const name = basename(command.value);
  const args = position.words.slice(position.index + 1);
  if (name === "find") {
    const { roots, expression } = findRoots(args);
    if (findIsShallow(expression)) return false;
    return roots.some((root) => isBroadRoot(root, homes));
  }
  const isGrep = GREP_COMMANDS.has(name);
  if (!isGrep && !RECURSIVE_SEARCHERS.has(name)) return false;
  const { operands, options, patternGiven } = parseOperands(args, isGrep ? GREP_VALUE_OPTIONS : SEARCHER_VALUE_OPTIONS);
  if (isGrep && !grepRecursive(command, options, args)) return false;
  if (name === "rg" && options.includes("--files")) return operands.some((root) => isBroadRoot(root, homes));
  const paths = patternGiven ? operands : operands.slice(1);
  return paths.some((root) => isBroadRoot(root, homes));
}

function decision(command) {
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return { decision: "allow" };
  const homes = homeDirectories();
  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    if (scansBroadly(commandPosition(node), homes)) {
      return { decision: "deny", code: "broad-scan", reason: REASON };
    }
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command);
      if (result.decision === "allow") process.stdout.write("allow\n");
      else process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
