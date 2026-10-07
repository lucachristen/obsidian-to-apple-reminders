import { fingerprint, type IdentityRecord, type Observation } from './identity';
import { withoutMarker } from './model';

export interface LinkSuggestion {
  target: Observation;
  title: string;
  location: string;
  before: string;
  after: string;
  reasons: string[];
}

function normalize(text: string): string {
  return text.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}
export function taskTitle(markdown: string): string {
  return withoutMarker(markdown).replace(/^\s*(?:[-*+]|\d+[.)])\s+\[[^\]]\]\s*/, '');
}
function titleWords(markdown: string): string {
  return normalize(taskTitle(markdown).split(/[📅⏳🛫✅🔁🏁⏫🔼🔽🔺⏬]/u)[0]);
}

/** Suggestions are presentation only: never assign identities or hide ambiguous matches. */
export function linkSuggestions(original: IdentityRecord, candidates: Observation[], query = ''): LinkSuggestion[] {
  const source = original.anchor;
  const sourceTitle = titleWords(source.markdown);
  const sourceWords = new Set(sourceTitle.split(' ').filter(Boolean));
  const terms = normalize(query).split(' ').filter(Boolean);
  return candidates.flatMap(target => {
    const current = target.anchor;
    const title = taskTitle(current.markdown);
    const searchable = normalize([title, current.path, current.before, current.after].join(' '));
    if (!terms.every(term => searchable.includes(term))) return [];
    let score = 0;
    const reasons: string[] = [];
    const currentTitle = titleWords(current.markdown);
    if (fingerprint(source.markdown) === fingerprint(current.markdown)) {
      score += 200; reasons.push('Unchanged task');
    } else if (sourceTitle && sourceTitle === currentTitle) {
      score += 120; reasons.push('Same title');
    } else {
      const words = new Set(currentTitle.split(' ').filter(Boolean));
      const shared = [...sourceWords].filter(word => words.has(word)).length;
      const overlap = shared / Math.max(1, new Set([...sourceWords, ...words]).size);
      score += overlap * 80;
      if (overlap >= 0.35) reasons.push('Similar title');
    }
    if (source.path === current.path) { score += 25; reasons.push('Same note'); }
    const sameBefore = !!source.before && source.before === current.before;
    const sameAfter = !!source.after && source.after === current.after;
    score += (Number(sameBefore) + Number(sameAfter)) * 20;
    if (sameBefore && sameAfter) reasons.push('Same surrounding context');
    else if (sameBefore || sameAfter) reasons.push('Shared context');
    return [{ target, title, location: `${current.path} · line ${current.line + 1}`, before: current.before, after: current.after, reasons, score }];
  }).sort((a, b) => b.score - a.score || a.target.anchor.path.localeCompare(b.target.anchor.path) || a.target.anchor.line - b.target.anchor.line)
    .map(({ score: _, ...suggestion }) => suggestion);
}
