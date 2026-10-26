import { fileURLToPath } from "node:url";
import { parseOrgWithDiagnostics } from "./parser.js";
import { lintPriorityCookies } from "./priorityLint.js";
import { evaluateTableNode, tablesInDocument } from "./tableFormula.js";
import { documentTodoSequences, todoSequencesForFile } from "./todo.js";

export interface Position {
  line: number;
  character: number;
}

export interface Range {
  start: Position;
  end: Position;
}

export interface Diagnostic {
  range: Range;
  severity: number;
  message: string;
  code?: string;
}

export interface PublishDiagnosticsParams {
  uri: string;
  diagnostics: Diagnostic[];
}

const DiagnosticSeverity = {
  Error: 1,
  Warning: 2,
} as const;

class DiagnosticLineTracker {
  private lines: string[];

  constructor(text: string) {
    this.lines = text.split("\n");
  }

  getLineLength(lineNum: number): number {
    return this.lines[lineNum]?.length || 0;
  }
}

/**
 * Build the LSP publishDiagnostics payload for org parser diagnostics.
 *
 * LSP positions are 0-based, while parser errors are 1-based.
 */
export function buildPublishDiagnosticsParams(uri: string, text: string): PublishDiagnosticsParams {
  let sourcePath: string | undefined;
  try { if (uri.startsWith("file:")) sourcePath = fileURLToPath(uri); } catch { /* Non-local URI: use document declarations. */ }
  const result = parseOrgWithDiagnostics(text, { sourceRanges: true, sourcePath });
  const tracker = new DiagnosticLineTracker(text);

  const diagnostics: Diagnostic[] = result.diagnostics.map((parseErr) => {
    const lspLine = Math.max(0, parseErr.line - 1);
    const lspColumn = Math.max(0, parseErr.column - 1);
    const endChar = tracker.getLineLength(lspLine);

    return {
      range: {
        start: { line: lspLine, character: lspColumn },
        // Highlight from error column to end-of-line (keeps it visible without guessing a width).
        end: { line: lspLine, character: Math.max(lspColumn, endChar) },
      },
      severity: DiagnosticSeverity.Error,
      message: parseErr.message,
      code: "org2-parser",
    };
  });

  for (const table of tablesInDocument(result.ast)) {
    const sourceRange = table.sourceRange;
    if (!sourceRange) continue;
    table.formulas?.forEach((_formula, formulaIndex) => {
      const evaluation = evaluateTableNode(table, formulaIndex);
      if (evaluation.ok) return;
      const line = sourceRange.endLine + formulaIndex;
      for (const issue of evaluation.diagnostics) {
        diagnostics.push({
          range: {
            start: { line, character: 0 },
            end: { line, character: tracker.getLineLength(line) },
          },
          severity: DiagnosticSeverity.Error,
          message: issue.message,
          code: "org2-table-formula",
        });
      }
    });
  }

  let todoSequences = result.ast.todoSequences;
  if (!todoSequences) {
    try { todoSequences = documentTodoSequences(text, todoSequencesForFile(sourcePath)); } catch { todoSequences = documentTodoSequences(text); }
  }
  for (const issue of lintPriorityCookies(text, { todoSequences })) {
    diagnostics.push({
      range: {
        start: { line: issue.line - 1, character: issue.column - 1 },
        end: { line: issue.line - 1, character: issue.endColumn - 1 },
      },
      severity: DiagnosticSeverity.Warning,
      message: issue.message,
      code: `org2-${issue.rule}`,
    });
  }

  return { uri, diagnostics };
}
