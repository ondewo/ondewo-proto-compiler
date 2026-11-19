// The linker gate of an Angular library bundle, shared by runtime-check.mjs and tests/angular_compat.bats.
//
// Angular's linker picks the linker for each ɵɵngDeclare* call by the declaration's `minVersion` and
// throws when that minVersion is newer than itself (unknownDeclarationVersionHandling: 'error'). The
// `version` stamp - the compiler that BUILT the library - is not consulted. So a library built by a
// newer Angular links on an older one as long as every minVersion is <= that older version.
//
// CLI: node declaration-gate.mjs <bundle.mjs> <angular_version>  -> exit 0 and a summary, or exit 1.
import { readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const parse = (version) => version.split('-')[0].split('.').map(Number);
const isNewer = (a, b) => {
  const [x, y] = [parse(a), parse(b)];
  for (let i = 0; i < 3; i++) {
    if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
  }
  return false;
};

/** @returns {{count: number, builtBy: string[], tooNew: string[]}} */
export function checkDeclarations(bundle, angularVersion) {
  // Angular <= 21 prints `({ minVersion: "…", version: "…"` on one line, 22 spreads it over several.
  const declarations = [...bundle.matchAll(/ɵɵngDeclare\w+\(\{\s*minVersion:\s*"([^"]+)",\s*version:\s*"([^"]+)"/g)];
  return {
    count: declarations.length,
    builtBy: [...new Set(declarations.map((m) => m[2]))],
    tooNew: [...new Set(declarations.map((m) => m[1]).filter((min) => isNewer(min, angularVersion)))],
  };
}

// import.meta.url is the REAL path, argv[1] the path as typed: compare real paths, or a run through a
// symlinked checkout skips this block and exits 0 without judging anything.
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [bundlePath, angularVersion] = process.argv.slice(2);
  const { count, builtBy, tooNew } = checkDeclarations(readFileSync(bundlePath, 'utf8'), angularVersion);
  if (count === 0) {
    console.error(`FAIL: no ɵɵngDeclare* partial declarations in ${bundlePath}`);
    process.exit(1);
  }
  if (tooNew.length > 0) {
    console.error(`FAIL: declarations need Angular >= ${tooNew.join(', ')}; Angular ${angularVersion} cannot link them`);
    process.exit(1);
  }
  console.log(`OK: ${count} partial declarations (built by Angular ${builtBy.join(', ')}) link on Angular ${angularVersion}`);
}
