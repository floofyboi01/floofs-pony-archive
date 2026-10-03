// Static checks for the channel source. No BrightScript compiler runs locally,
// so this catches the classes of mistake that otherwise only surface as a
// blank screen on the device: unbalanced blocks, observer callbacks that don't
// exist, findNode() ids missing from the XML, and typo'd helper calls.

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const problems = [];
const notes = [];

const read = p => fs.readFileSync(p, 'utf8');
const brsFiles = [];
const xmlFiles = [];

for (const dir of ['source', 'components']) {
  const full = path.join(root, dir);
  if (!fs.existsSync(full)) continue;
  for (const f of fs.readdirSync(full)) {
    const p = path.join(full, f);
    if (f.endsWith('.brs')) brsFiles.push(p);
    if (f.endsWith('.xml')) xmlFiles.push(p);
  }
}

//---------------------------------------------------------------
// Strip comments and string literals so keywords inside them don't count.
//---------------------------------------------------------------
function codeLines(src) {
  return src.split(/\r?\n/).map(raw => {
    let out = '';
    let inStr = false;
    for (let i = 0; i < raw.length; i++) {
      const c = raw[i];
      if (c === '"') { inStr = !inStr; out += ' '; continue; }
      if (inStr) { out += ' '; continue; }
      if (c === "'") break;            // comment to end of line
      out += c;
    }
    // A bare "REM" comment also runs to end of line.
    const remAt = out.search(/\bREM\b/i);
    if (remAt >= 0) out = out.slice(0, remAt);
    return out;
  });
}

// Same as codeLines but keeps REM, so the reserved-word scan can actually see
// `rem = ...`. Stripping it first is what hid the bug in the first place.
function codeLinesKeepRem(src) {
  return src.split(/\r?\n/).map(raw => {
    let out = '';
    let inStr = false;
    for (let i = 0; i < raw.length; i++) {
      const c = raw[i];
      if (c === '"') { inStr = !inStr; out += ' '; continue; }
      if (inStr) { out += ' '; continue; }
      if (c === "'") break;
      out += c;
    }
    return out;
  });
}

//---------------------------------------------------------------
// 1. Block balance
//---------------------------------------------------------------
function checkBlocks(file, src) {
  const lines = codeLines(src);
  const stack = [];
  const name = path.basename(file);

  lines.forEach((line, i) => {
    const lno = i + 1;
    const t = line.trim();
    if (!t) return;
    const low = t.toLowerCase();

    // Openers
    if (/^(sub|function)\b/.test(low)) stack.push({ kind: low.startsWith('sub') ? 'sub' : 'function', lno });
    else if (/^end\s+(sub|function)\b/.test(low)) {
      const want = low.includes('sub') ? 'sub' : 'function';
      const top = stack.pop();
      if (!top) problems.push(`${name}:${lno}  "end ${want}" with nothing open`);
      else if (top.kind !== want) problems.push(`${name}:${lno}  "end ${want}" closes a ${top.kind} opened at line ${top.lno}`);
      return;
    }

    if (/^for\b/.test(low)) stack.push({ kind: 'for', lno });
    else if (/^(end\s+for|next)\b/.test(low)) {
      const top = stack.pop();
      if (!top || top.kind !== 'for') problems.push(`${name}:${lno}  "end for" does not match (top=${top ? top.kind + '@' + top.lno : 'empty'})`);
    }

    else if (/^while\b/.test(low)) stack.push({ kind: 'while', lno });
    else if (/^end\s+while\b/.test(low)) {
      const top = stack.pop();
      if (!top || top.kind !== 'while') problems.push(`${name}:${lno}  "end while" does not match (top=${top ? top.kind + '@' + top.lno : 'empty'})`);
    }

    else if (/^if\b/.test(low)) {
      // Multi-line if = the line ends with "then" (or has no "then" at all).
      const m = low.match(/\bthen\b(.*)$/);
      const isBlock = m ? m[1].trim() === '' : true;
      if (isBlock) stack.push({ kind: 'if', lno });
    }
    else if (/^end\s+if\b/.test(low)) {
      const top = stack.pop();
      if (!top || top.kind !== 'if') problems.push(`${name}:${lno}  "end if" does not match (top=${top ? top.kind + '@' + top.lno : 'empty'})`);
    }
    else if (/^else\s+if\b/.test(low) || /^elseif\b/.test(low)) {
      if (!stack.length || stack[stack.length - 1].kind !== 'if')
        problems.push(`${name}:${lno}  "else if" outside an if block`);
    }
    else if (/^else\b/.test(low)) {
      if (!stack.length || stack[stack.length - 1].kind !== 'if')
        problems.push(`${name}:${lno}  "else" outside an if block`);
    }
  });

  if (stack.length) {
    stack.forEach(s => problems.push(`${name}  unclosed ${s.kind} opened at line ${s.lno}`));
  }
}

//---------------------------------------------------------------
// 2. Collect declared routines
//---------------------------------------------------------------
// SceneGraph lifecycle hooks are per-component by design.
const PER_COMPONENT_HOOKS = new Set(['init', 'onkeyevent']);

const declared = new Map();   // lowercase name -> { file, scope }
for (const f of brsFiles) {
  const src = read(f);
  const scope = path.basename(path.dirname(f)) === 'source' ? 'global' : 'component';
  codeLines(src).forEach(line => {
    const m = line.trim().match(/^(?:sub|function)\s+([A-Za-z_][A-Za-z0-9_]*)/i);
    if (!m) return;
    const key = m[1].toLowerCase();
    const prev = declared.get(key);

    if (prev && prev.file !== path.basename(f) && !PER_COMPONENT_HOOKS.has(key)) {
      // Only source/ is truly global. Two components may reuse a name, but a
      // component routine shadowing a global one is a genuine hazard.
      if (prev.scope === 'global' || scope === 'global') {
        problems.push(`routine "${m[1]}" in ${path.basename(f)} (${scope}) collides with ${prev.file} (${prev.scope})`);
      }
    }
    declared.set(key, { file: path.basename(f), scope });
  });
}

//---------------------------------------------------------------
// 2b. Reserved words used as identifiers
//
// BrightScript inherits BASIC's keyword list. The nastiest is "rem", which
// starts a comment, so `rem = x` silently eats the rest of the line and the
// compiler reports a syntax error on some *later* line.
//---------------------------------------------------------------
const RESERVED = new Set([
  'and', 'box', 'createobject', 'dim', 'each', 'else', 'elseif', 'end',
  'endfunction', 'endif', 'endsub', 'endwhile', 'eval', 'exit', 'exitwhile',
  'false', 'for', 'function', 'getglobalaa', 'goto', 'if', 'invalid', 'let',
  'line_num', 'next', 'not', 'objfun', 'or', 'pos', 'print', 'rem', 'return',
  'run', 'step', 'stop', 'sub', 'tab', 'then', 'to', 'true', 'type', 'while',
  'library', 'mod', 'as', 'in',
]);

for (const f of brsFiles) {
  const name = path.basename(f);
  codeLinesKeepRem(read(f)).forEach((line, i) => {
    const lno = i + 1;
    const t = line.trim();
    if (!t) return;

    // Plain assignment:  foo = ...   (but not == or >= etc.)
    const assign = t.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=[^=]/);
    if (assign && RESERVED.has(assign[1].toLowerCase())) {
      problems.push(`${name}:${lno}  reserved word "${assign[1]}" used as a variable`);
    }

    // for each <var> in ...
    const each = t.match(/^for\s+each\s+([A-Za-z_][A-Za-z0-9_]*)/i);
    if (each && RESERVED.has(each[1].toLowerCase())) {
      problems.push(`${name}:${lno}  reserved word "${each[1]}" used as a loop variable`);
    }

    // for <var> = ...
    const forVar = t.match(/^for\s+([A-Za-z_][A-Za-z0-9_]*)\s*=/i);
    if (forVar && RESERVED.has(forVar[1].toLowerCase())) {
      problems.push(`${name}:${lno}  reserved word "${forVar[1]}" used as a loop variable`);
    }

    // Parameter names in a signature.
    const sig = t.match(/^(?:sub|function)\s+[A-Za-z_][A-Za-z0-9_]*\s*\(([^)]*)\)/i);
    if (sig && sig[1].trim()) {
      for (const param of sig[1].split(',')) {
        const pname = param.trim().split(/\s+/)[0];
        if (pname && RESERVED.has(pname.toLowerCase())) {
          problems.push(`${name}:${lno}  reserved word "${pname}" used as a parameter`);
        }
      }
    }

    // Reserved word used as an associative-array key shorthand { rem: 1 }
    for (const m of t.matchAll(/([A-Za-z_][A-Za-z0-9_]*)\s*:/g)) {
      if (RESERVED.has(m[1].toLowerCase()) && !/^\s*(else|end)/i.test(t)) {
        problems.push(`${name}:${lno}  reserved word "${m[1]}" used as an AA key`);
      }
    }
  });
}

//---------------------------------------------------------------
// 2c. Interface methods called as if they were global functions
//
// BrightScript has global Mid/Left/Len/Instr/UCase/... but Trim, Replace,
// Split and friends exist only as methods on the value. Calling Trim(x)
// raises "Function Call Operator ( ) attempted on non-function (&he0)"
// at runtime, and only on the code path that executes it.
//---------------------------------------------------------------
const METHOD_ONLY = [
  'Trim', 'Replace', 'Split', 'Tokenize', 'StartsWith', 'EndsWith',
  'ToInt', 'ToFloat', 'GetEntityEncode', 'Escape', 'Unescape',
  'Count', 'Push', 'Pop', 'Peek', 'Shift', 'Unshift', 'Join', 'Sort',
  'Reverse', 'Append', 'Clear', 'Delete', 'DoesExist', 'Keys', 'Items',
  'Lookup', 'AddReplace', 'GetChildCount', 'CreateChild',
];

for (const f of brsFiles) {
  const name = path.basename(f);
  codeLines(read(f)).forEach((line, i) => {
    const lno = i + 1;
    if (/^\s*(?:sub|function)\b/i.test(line)) return;
    for (const fn of METHOD_ONLY) {
      // Match the bare call form, i.e. not preceded by "." or a word char.
      const re = new RegExp(`(^|[^\\w.])${fn}\\s*\\(`, 'i');
      if (re.test(line)) {
        problems.push(`${name}:${lno}  ${fn}() called as a global function; it only exists as a method (use value.${fn}())`);
      }
    }
  });
}

//---------------------------------------------------------------
// 3. observeField / functionName callbacks must exist
//---------------------------------------------------------------
for (const f of brsFiles) {
  const src = read(f);
  const name = path.basename(f);

  for (const m of src.matchAll(/observeField\s*\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)/g)) {
    if (!declared.has(m[2].toLowerCase())) {
      problems.push(`${name}  observeField("${m[1]}", "${m[2]}") -> no such routine`);
    }
  }
  for (const m of src.matchAll(/functionName\s*=\s*"([^"]+)"/g)) {
    if (!declared.has(m[1].toLowerCase())) {
      problems.push(`${name}  functionName = "${m[1]}" -> no such routine`);
    }
  }
}

//---------------------------------------------------------------
// 3b. Every routine a component calls must be reachable from that component
//
// Scripts under source/ are in scope for the main thread only. A component
// that calls a shared helper must pull it in with its own <script> tag, or
// the call fails at runtime with "Function is not defined in component's
// namespace (&h91)" -- which only shows up when that code path executes.
//---------------------------------------------------------------
const BRS_BUILTINS = new Set([
  'createobject', 'type', 'getglobalaa', 'box', 'run', 'eval', 'parsejson',
  'formatjson', 'instr', 'mid', 'left', 'right', 'len', 'val', 'str', 'stri',
  'chr', 'asc', 'ucase', 'lcase', 'trim', 'abs', 'int', 'cint', 'fix', 'sgn',
  'sqr', 'log', 'exp', 'sin', 'cos', 'tan', 'atn', 'rnd', 'strtoi', 'string',
  'stringi', 'substitute', 'tostr', 'wait', 'sleep', 'uptime', 'rebootsystem',
  'readasciifile', 'writeasciifile', 'listdir', 'matchfiles', 'copyfile',
  'movefile', 'deletefile', 'deletedirectory', 'createdirectory',
  'formatdrive', 'getinterface', 'findmemberfunction', 'print', 'linenum',
  'main', 'runuserinterface', 'showchannelstorelegalnotice', 'tab', 'pos',
  'asctime', 'rungarbagecollector', 'sprintf', 'lineno',
]);

for (const brsPath of brsFiles) {
  const dir = path.basename(path.dirname(brsPath));
  if (dir !== 'components') continue;

  const xmlPath = brsPath.replace(/\.brs$/, '.xml');
  if (!fs.existsSync(xmlPath)) continue;

  const xml = read(xmlPath);
  const included = [...xml.matchAll(/<script[^>]*uri\s*=\s*"pkg:\/([^"]+)"/g)].map(m => m[1]);

  // Routines reachable from this component: its own script plus every
  // script its XML includes.
  const reachable = new Set();
  for (const rel of included) {
    const target = path.join(root, rel.replace(/\//g, path.sep));
    if (!fs.existsSync(target)) continue;
    codeLines(read(target)).forEach(line => {
      const m = line.trim().match(/^(?:sub|function)\s+([A-Za-z_][A-Za-z0-9_]*)/i);
      if (m) reachable.add(m[1].toLowerCase());
    });
  }

  const src = read(brsPath);
  const name = path.basename(brsPath);
  const reported = new Set();

  codeLines(src).forEach((line, i) => {
    const lno = i + 1;
    // Bare calls of the form name(...) that are not method calls (no dot
    // before) and not a declaration.
    if (/^\s*(?:sub|function)\b/i.test(line)) return;

    for (const m of line.matchAll(/(^|[^\w.$])([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) {
      const fn = m[2];
      const key = fn.toLowerCase();
      if (BRS_BUILTINS.has(key) || RESERVED.has(key)) continue;
      if (reachable.has(key)) continue;
      if (reported.has(key)) continue;
      // Only flag things we know are declared somewhere in the project;
      // anything else is a component/node method we can't resolve statically.
      if (!declared.has(key)) continue;

      reported.add(key);
      const where = declared.get(key);
      problems.push(`${name}:${lno}  calls ${fn}() from ${where.file}, but ${path.basename(xmlPath)} does not <script> it in`);
    }
  });
}

//---------------------------------------------------------------
// 4. findNode() ids must exist in the paired XML
//---------------------------------------------------------------
function xmlIds(src) {
  return new Set([...src.matchAll(/\bid\s*=\s*"([^"]+)"/g)].map(m => m[1]));
}

for (const f of brsFiles) {
  const xmlPath = f.replace(/\.brs$/, '.xml');
  if (!fs.existsSync(xmlPath)) continue;
  const ids = xmlIds(read(xmlPath));
  const src = read(f);
  const name = path.basename(f);

  for (const m of src.matchAll(/findNode\s*\(\s*"([^"]+)"\s*\)/g)) {
    if (!ids.has(m[1])) {
      problems.push(`${name}  findNode("${m[1]}") -> id not present in ${path.basename(xmlPath)}`);
    }
  }
}

//---------------------------------------------------------------
// 5. Interface fields used via m.top.<field> on Task components
//---------------------------------------------------------------
const BUILTIN_NODE_FIELDS = new Set([
  'functionname', 'control', 'state', 'id', 'focusedchild', 'change',
  'visible', 'opacity', 'translation', 'scale', 'rotation', 'content',
  'backgrounduri', 'backgroundcolor', 'width', 'height',
]);

for (const xmlPath of xmlFiles) {
  const xml = read(xmlPath);
  const brsPath = xmlPath.replace(/\.xml$/, '.brs');
  if (!fs.existsSync(brsPath)) continue;

  const ifaceFields = new Set(
    [...xml.matchAll(/<field\s+[^>]*id\s*=\s*"([^"]+)"/g)].map(m => m[1].toLowerCase())
  );
  const src = read(brsPath);
  const name = path.basename(brsPath);

  for (const m of src.matchAll(/m\.top\.([A-Za-z_][A-Za-z0-9_]*)/g)) {
    // Skip method calls such as m.top.findNode(...) / m.top.observeField(...).
    // A lookahead here would let the identifier match one char short, so
    // inspect the following character directly instead.
    const after = src.slice(m.index + m[0].length).match(/^\s*\(/);
    if (after) continue;

    const field = m[1].toLowerCase();
    if (BUILTIN_NODE_FIELDS.has(field)) continue;
    if (!ifaceFields.has(field)) {
      problems.push(`${name}  m.top.${m[1]} is not declared in ${path.basename(xmlPath)} <interface>`);
    }
  }
}

//---------------------------------------------------------------
// 6. XML tag balance + script uri existence
//---------------------------------------------------------------
for (const xmlPath of xmlFiles) {
  // Strip comments first: prose inside <!-- --> legitimately mentions things
  // like <Font> and <Name>, which would otherwise look like real tags.
  const xml = read(xmlPath).replace(/<!--[\s\S]*?-->/g, '');
  const name = path.basename(xmlPath);

  const stack = [];
  const tagRe = /<(\/?)([A-Za-z_][\w:.-]*)((?:[^>"']|"[^"]*"|'[^']*')*?)(\/?)>/g;
  for (const m of xml.matchAll(tagRe)) {
    const [, closing, tag, , selfClose] = m;
    if (closing) {
      const top = stack.pop();
      if (top !== tag) problems.push(`${name}  </${tag}> does not close <${top || 'nothing'}>`);
    } else if (!selfClose) {
      stack.push(tag);
    }
  }
  if (stack.length) problems.push(`${name}  unclosed XML tags: ${stack.join(', ')}`);

  for (const m of xml.matchAll(/uri\s*=\s*"pkg:\/([^"]+)"/g)) {
    const target = path.join(root, m[1].replace(/\//g, path.sep));
    if (!fs.existsSync(target)) problems.push(`${name}  script uri pkg:/${m[1]} does not exist`);
  }

  // A <Font> node's uri only accepts a font file shipped in the package.
  // "font:SystemBoldFontFile" resolves to nothing and renders invisible text.
  for (const m of xml.matchAll(/<Font\b[^>]*uri\s*=\s*"([^"]+)"/g)) {
    if (!m[1].startsWith('pkg:/')) {
      problems.push(`${name}  <Font uri="${m[1]}"> is not a packaged font file; use the font="font:<Name>SystemFont" shorthand instead`);
    }
  }

  // The shorthand must name a real system font.
  const SYSTEM_FONTS = new Set([
    'TinySystemFont', 'TinyBoldSystemFont', 'SmallerSystemFont',
    'SmallerBoldSystemFont', 'SmallestSystemFont', 'SmallestBoldSystemFont',
    'SmallSystemFont', 'SmallBoldSystemFont', 'MediumSystemFont',
    'MediumBoldSystemFont', 'LargeSystemFont', 'LargeBoldSystemFont',
    'LargestSystemFont', 'ExtraLargeSystemFont', 'ExtraLargeBoldSystemFont',
    'BadgeSystemFont',
  ]);
  for (const m of xml.matchAll(/(?:^|\s)(?:focused)?[Ff]ont\s*=\s*"font:([^"]+)"/g)) {
    if (!SYSTEM_FONTS.has(m[1])) {
      problems.push(`${name}  font:${m[1]} is not a documented system font`);
    }
  }

  // Components referenced by CreateObject("roSGNode", "X") should be real.
  const compName = xml.match(/<component\s+[^>]*name\s*=\s*"([^"]+)"/);
  if (compName) notes.push(`component ${compName[1]} <- ${name}`);
}

//---------------------------------------------------------------
// 7. CreateObject("roSGNode", "Custom") must resolve to a component
//---------------------------------------------------------------
const componentNames = new Set();
for (const xmlPath of xmlFiles) {
  const m = read(xmlPath).match(/<component\s+[^>]*name\s*=\s*"([^"]+)"/);
  if (m) componentNames.add(m[1]);
}
const ROKU_BUILTIN_NODES = new Set([
  'ContentNode', 'Timer', 'Node', 'Group', 'Label', 'Rectangle', 'Poster',
  'LabelList', 'MarkupList', 'Video', 'Audio', 'Animation', 'Font', 'Task',
]);
for (const f of brsFiles) {
  const src = read(f);
  for (const m of src.matchAll(/CreateObject\s*\(\s*"roSGNode"\s*,\s*"([^"]+)"\s*\)/g)) {
    if (!componentNames.has(m[1]) && !ROKU_BUILTIN_NODES.has(m[1])) {
      problems.push(`${path.basename(f)}  CreateObject("roSGNode","${m[1]}") -> unknown component`);
    }
  }
}

//---------------------------------------------------------------
// Report
//---------------------------------------------------------------
console.log(`scanned ${brsFiles.length} .brs and ${xmlFiles.length} .xml files`);
console.log(`declared ${declared.size} routines, ${componentNames.size} components\n`);

for (const f of brsFiles) checkBlocks(f, read(f));

if (problems.length === 0) {
  console.log('PASS - no structural problems found');
} else {
  console.log(`FAIL - ${problems.length} problem(s):`);
  problems.forEach(p => console.log('  ' + p));
  process.exitCode = 1;
}
