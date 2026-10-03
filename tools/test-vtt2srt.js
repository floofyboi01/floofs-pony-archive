// Faithful JS transliteration of the BrightScript VTT->SRT converter in
// source/Util.brs, exercised against real files from the archive.
//
// The point is to validate the *algorithm* (indexing, folding, timestamp
// rewriting) before it ever runs on the device, since BrightScript's 1-based
// string functions are easy to get subtly wrong.

//--- BrightScript string primitives -------------------------------
const Len = s => s.length;
const Mid = (s, start, len) => (len === undefined ? s.substring(start - 1) : s.substr(start - 1, len));
const Instr = (start, s, sub) => s.indexOf(sub, start - 1) + 1;
const Left = (s, n) => s.substring(0, n);
const Trim = s => s.replace(/^[\s]+|[\s]+$/g, '');
const LCase = s => s.toLowerCase();
const Asc = c => c.charCodeAt(0);
const Chr = n => String.fromCharCode(n);
const Str = n => ' ' + String(n);
const Val = s => { const v = parseFloat(s); return isNaN(v) ? 0 : v; };
const Int = n => Math.trunc(n);

function paPad2(n) { return n < 10 ? '0' + Trim(Str(n)) : Trim(Str(n)); }

//--- Ported functions ---------------------------------------------

function paNormaliseTimestamp(ts) {
  let t = Trim(ts);
  if (t === '') return '';
  t = t.split(',').join('.');

  let dotAt = 0;
  for (let idx = Len(t); idx >= 1; idx--) {
    if (Mid(t, idx, 1) === '.') { dotAt = idx; break; }
  }

  let millis = '000';
  let head = t;
  if (dotAt > 0) {
    head = Mid(t, 1, dotAt - 1);
    millis = Mid(t, dotAt + 1);
  }
  while (Len(millis) < 3) millis = millis + '0';
  millis = Mid(millis, 1, 3);

  const bits = head.split(':');
  let hh = 0, mm = 0, ss = 0;
  if (bits.length === 3) {
    hh = Int(Val(bits[0])); mm = Int(Val(bits[1])); ss = Int(Val(bits[2]));
  } else if (bits.length === 2) {
    mm = Int(Val(bits[0])); ss = Int(Val(bits[1]));
  } else {
    return '';
  }
  return paPad2(hh) + ':' + paPad2(mm) + ':' + paPad2(ss) + ',' + millis;
}

function paParseCueTiming(line) {
  const arrowAt = Instr(1, line, '-->');
  if (arrowAt <= 0) return null;

  const startRaw = Trim(Mid(line, 1, arrowAt - 1));
  let endRaw = Trim(Mid(line, arrowAt + 3));

  let cut = Instr(1, endRaw, ' ');
  if (cut > 0) endRaw = Mid(endRaw, 1, cut - 1);
  cut = Instr(1, endRaw, Chr(9));
  if (cut > 0) endRaw = Mid(endRaw, 1, cut - 1);

  const startTs = paNormaliseTimestamp(startRaw);
  const endTs = paNormaliseTimestamp(endRaw);
  if (startTs === '' || endTs === '') return null;
  return { start: startTs, finish: endTs };
}

function paStripVttTags(line) {
  if (Instr(1, line, '<') <= 0) return line;

  let result = '';
  let i = 1;
  const total = Len(line);
  while (i <= total) {
    const ch = Mid(line, i, 1);
    if (ch === '<') {
      const closeAt = Instr(i, line, '>');
      if (closeAt <= 0) { result = result + Mid(line, i); break; }
      let tag = Mid(line, i + 1, closeAt - i - 1);
      if (Left(tag, 1) === '/') tag = Mid(tag, 2);
      tag = LCase(Trim(tag));
      if (tag === 'i' || tag === 'b' || tag === 'u') {
        result = result + Mid(line, i, closeAt - i + 1);
      }
      i = closeAt + 1;
    } else {
      result = result + ch;
      i = i + 1;
    }
  }
  return result;
}

function paVttToSrt(vtt) {
  if (vtt === null || vtt === undefined || Len(vtt) === 0) return '';

  let text = vtt;
  if (Len(text) >= 3 && Asc(Mid(text, 1, 1)) === 65279) text = Mid(text, 2);
  text = text.split(Chr(13) + Chr(10)).join(Chr(10));
  text = text.split(Chr(13)).join(Chr(10));

  const lines = text.split(Chr(10));
  const total = lines.length;

  const chunks = [];
  let buffer = '';
  let cueIndex = 0;
  let i = 0;

  while (i < total) {
    const line = lines[i];
    if (Instr(1, line, '-->') > 0) {
      const timing = paParseCueTiming(line);
      if (timing === null) {
        i = i + 1;
      } else {
        const body = [];
        let j = i + 1;
        while (j < total) {
          if (Trim(lines[j]) === '') break;
          if (Instr(1, lines[j], '-->') > 0) break;
          body.push(paStripVttTags(lines[j]));
          j = j + 1;
        }
        if (body.length > 0) {
          cueIndex = cueIndex + 1;
          buffer = buffer + Trim(Str(cueIndex)) + Chr(10);
          buffer = buffer + timing.start + ' --> ' + timing.finish + Chr(10);
          for (const bodyLine of body) buffer = buffer + bodyLine + Chr(10);
          buffer = buffer + Chr(10);
          if (Len(buffer) > 8192) { chunks.push(buffer); buffer = ''; }
        }
        i = j;
      }
    } else {
      i = i + 1;
    }
  }

  if (buffer !== '') chunks.push(buffer);
  if (cueIndex === 0) return '';
  return chunks.join('');
}

//--- Validation ---------------------------------------------------

const TS = /^(\d{2}):(\d{2}):(\d{2}),(\d{3})$/;
const toMs = ts => {
  const m = ts.match(TS);
  return (+m[1]) * 3600000 + (+m[2]) * 60000 + (+m[3]) * 1000 + (+m[4]);
};

function validateSrt(srt, sourceVtt, name, problems) {
  const blocks = srt.split('\n\n').filter(b => b.trim() !== '');
  const vttCueCount = sourceVtt.split('\n').filter(l => l.includes('-->')).length;

  if (blocks.length !== vttCueCount) {
    problems.push(`${name}: cue count ${blocks.length} != source ${vttCueCount}`);
  }

  let prevStart = -1;
  blocks.forEach((block, idx) => {
    const lines = block.split('\n');
    if (lines.length < 3) { problems.push(`${name}: block ${idx + 1} has < 3 lines`); return; }

    if (lines[0] !== String(idx + 1)) {
      problems.push(`${name}: block ${idx + 1} index is "${lines[0]}"`);
    }

    const parts = lines[1].split(' --> ');
    if (parts.length !== 2 || !TS.test(parts[0]) || !TS.test(parts[1])) {
      problems.push(`${name}: block ${idx + 1} bad timing "${lines[1]}"`);
      return;
    }

    const a = toMs(parts[0]), b = toMs(parts[1]);
    if (b <= a) problems.push(`${name}: block ${idx + 1} end <= start (${lines[1]})`);
    if (a < prevStart) problems.push(`${name}: block ${idx + 1} starts before previous`);
    prevStart = a;

    if (lines.slice(2).join('').trim() === '') {
      problems.push(`${name}: block ${idx + 1} has empty text`);
    }
  });

  // Every non-timing, non-blank source line must survive into the output.
  const srcText = sourceVtt.split('\n')
    .filter(l => l.trim() !== '' && !l.includes('-->') && l.trim() !== 'WEBVTT')
    .map(l => l.replace(/<[^>]*>/g, '').trim()).filter(Boolean);
  const outText = blocks.flatMap(b => b.split('\n').slice(2))
    .map(l => l.replace(/<[^>]*>/g, '').trim()).filter(Boolean);
  if (srcText.length !== outText.length) {
    problems.push(`${name}: text line count ${outText.length} != source ${srcText.length}`);
  } else {
    for (let k = 0; k < srcText.length; k++) {
      if (srcText[k] !== outText[k]) {
        problems.push(`${name}: text drift at line ${k}: "${srcText[k]}" -> "${outText[k]}"`);
        break;
      }
    }
  }
}

//--- Synthetic edge cases -----------------------------------------

function runSynthetic() {
  console.log('--- synthetic edge cases ---');
  const cases = [
    ['no hours field', 'WEBVTT\n\n01:02.500 --> 01:04.000\nHi\n', '00:01:02,500 --> 00:01:04,000'],
    ['cue settings', 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000 align:start position:10%\nHi\n', '00:00:01,000 --> 00:00:02,000'],
    ['cue identifier', 'WEBVTT\n\nintro-1\n00:00:01.000 --> 00:00:02.000\nHi\n', '00:00:01,000 --> 00:00:02,000'],
    ['CRLF', 'WEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.000\r\nHi\r\n', '00:00:01,000 --> 00:00:02,000'],
    ['BOM', '\uFEFFWEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n', '00:00:01,000 --> 00:00:02,000'],
    ['2-digit millis', 'WEBVTT\n\n00:00:01.5 --> 00:00:02.25\nHi\n', '00:00:01,500 --> 00:00:02,250'],
    ['hours > 9', 'WEBVTT\n\n10:00:01.000 --> 10:00:02.000\nHi\n', '10:00:01,000 --> 10:00:02,000'],
  ];
  let pass = 0;
  for (const [label, input, expectTiming] of cases) {
    const out = paVttToSrt(input);
    const ok = out.includes(expectTiming) && out.startsWith('1\n');
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}`);
    if (!ok) console.log(`        got: ${JSON.stringify(out)}`);
    if (ok) pass++;
  }

  // Tag handling
  const tagOut = paVttToSrt('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<i>soft</i> <c.loud>LOUD</c> <v Spike>hey</v>\n');
  const tagLine = tagOut.split('\n')[2];
  const tagOk = tagLine === '<i>soft</i> LOUD hey';
  console.log(`  ${tagOk ? 'PASS' : 'FAIL'}  tag filtering`);
  if (!tagOk) console.log(`        got: ${JSON.stringify(tagLine)}`);
  if (tagOk) pass++;

  // Multi-line cue must stay in one block
  const multi = paVttToSrt('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nline one\nline two\n\n00:00:03.000 --> 00:00:04.000\nline three\n');
  const multiOk = multi.split('\n\n').filter(Boolean).length === 2 && multi.includes('line one\nline two');
  console.log(`  ${multiOk ? 'PASS' : 'FAIL'}  multi-line cue`);
  if (multiOk) pass++;

  // Garbage in must not produce garbage out
  const empty = paVttToSrt('WEBVTT\n\nnot a cue\n');
  const emptyOk = empty === '';
  console.log(`  ${emptyOk ? 'PASS' : 'FAIL'}  no usable cues returns empty`);
  if (emptyOk) pass++;

  console.log(`  ${pass}/${cases.length + 3} synthetic checks passed\n`);
  return pass === cases.length + 3;
}

//--- Real corpus --------------------------------------------------

const pad = n => String(n).padStart(2, '0');

(async () => {
  const syntheticOk = runSynthetic();

  const targets = [];
  for (const [s, e] of [[1,1],[1,26],[2,13],[3,1],[4,26],[5,1],[6,8],[7,11],[8,2],[9,26],[10,1],[10,2],[11,1],[12,1],[13,1],[14,1],[14,23]])
    targets.push(['https://static.heartshine.gay/g4-fim/vtt/', `s${pad(s)}e${pad(e)}-en.vtt`]);
  for (const [s, e] of [[1,1],[1,4],[2,1],[3,1]])
    targets.push(['https://static2.heartshine.gay/g4-eqg/vtt/', `s${pad(s)}e${pad(e)}-en.vtt`]);

  console.log('--- real corpus (English tracks) ---');
  const problems = [];
  let converted = 0, missing = 0, totalCues = 0;

  for (const [base, name] of targets) {
    let res;
    try { res = await fetch(base + name); } catch (e) { problems.push(`${name}: ${e.message}`); continue; }
    if (!res.ok) { missing++; console.log(`  skip  ${name} (HTTP ${res.status})`); continue; }

    const vtt = await res.text();
    const srt = paVttToSrt(vtt);
    if (srt === '') { problems.push(`${name}: produced no output`); continue; }

    validateSrt(srt, vtt.replace(/\r\n/g, '\n'), name, problems);
    const cues = srt.split('\n\n').filter(b => b.trim()).length;
    totalCues += cues;
    converted++;
    console.log(`  ok    ${name.padEnd(18)} ${String(cues).padStart(4)} cues  ${String(vtt.length).padStart(6)}B vtt -> ${String(srt.length).padStart(6)}B srt`);
  }

  console.log(`\nconverted ${converted} files, ${totalCues} cues total, ${missing} absent`);
  if (problems.length) {
    console.log(`\n!! ${problems.length} PROBLEM(S):`);
    problems.slice(0, 40).forEach(p => console.log('   ' + p));
    process.exitCode = 1;
  } else {
    console.log('all real-corpus conversions validated clean');
  }
  if (!syntheticOk) process.exitCode = 1;
})();
