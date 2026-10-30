import { crmCreate, crmFollowUp, crmIndex, crmLink, crmResolve, crmSchedule, crmSet, crmShow, crmUpcoming, crmWarm } from "./crm.js";

const HELP = `celorga crm

People & Companies: a lightweight CRM computed from the corpus. People and
companies are entity notes (:ORG2_ENTITY_TYPE: person|company); stage, domain,
email, role and owner are ordinary properties (CRM_STAGE, DOMAIN, EMAIL, ROLE,
OWNER, COMPANY); tasks are TODO headings; meetings are meeting headings;
outreach history comes from work-ledger accounts; upcoming meetings come from
staged calendar events under raw/.

Usage:
  celorga crm list --dir CORPUS [--kind people|companies] [--stage STAGE] [--query TEXT] [--limit N] [--details [--days N]]
  celorga crm warm --dir CORPUS [--rebuild]
  celorga crm show REF --dir CORPUS [--days N]
  celorga crm resolve QUERY --dir CORPUS
  celorga crm set REF --field stage|domain|email|role|owner|company --value TEXT --dir CORPUS [--if-revision SHA] [--apply]
  celorga crm follow-up REF --title TEXT [--scheduled DATE[ HH:MM]] [--deadline DATE] [--priority A] --dir CORPUS [--apply]
  celorga crm create person|company --title TEXT [--domain D] [--email E] [--role R] [--stage S] [--company REF] [--from-ledger LEDGER/ID] --dir CORPUS [--apply]
  celorga crm link --dir CORPUS [--only ID[,ID]] [--apply]
  celorga crm upcoming --dir CORPUS [--days N]
  celorga crm schedule --dir CORPUS [--days N] [--hours 09:00-17:00] [--duration MINUTES] [--overdue-days N] [--weekends] [--only TASK_KEY[,KEY]] [--apply]

Reads use a machine-local snapshot that is reused until a source file, ledger
account, staged calendar file or celorga.json changes; warm builds it ahead of
time. list --details also returns each entity's tasks, activity and upcoming
meetings. Activity separates meetings a person or company attended
(lastTouchAt) from meetings and notes that only mention them (lastMentionAt).
REF is an ID, title, alias, email, domain, or ledger:LEDGER/ACCOUNT_ID.
link proposes explicit links (ledger account → company note, person → company,
email, domain) for matches Celorga inferred. schedule proposes free calendar
slots for due People & Companies follow-ups and rewrites only SCHEDULED lines.
All responses are JSON. Writes preview by default; pass --apply to write.
Optional celorga.json keys: crm.stages, crm.include, crm.selfDomains.`;

const VALUE_FLAGS = new Set(["--dir", "--kind", "--stage", "--query", "--limit", "--days", "--field", "--value", "--if-revision", "--title", "--scheduled", "--deadline", "--priority", "--domain", "--email", "--role", "--company", "--from-ledger", "--only", "--hours", "--duration", "--overdue-days", "--now"]);
const BOOLEAN_FLAGS = new Set(["--apply", "--json", "--weekends", "--details", "--rebuild"]);

export async function runCrmCommand(args: string[]): Promise<void> {
  if (!args.length || args.includes("--help") || args.includes("-h")) { process.stdout.write(HELP + "\n"); return; }
  const values = [...args];
  const action = values.shift()!;
  const positional: string[] = [];
  const flags = new Map<string, string>();
  const booleans = new Set<string>();
  while (values.length) {
    const token = values.shift()!;
    if (BOOLEAN_FLAGS.has(token)) { booleans.add(token); continue; }
    if (VALUE_FLAGS.has(token)) {
      if (flags.has(token)) throw new Error(`Duplicate crm option: ${token}`);
      const value = values.shift();
      if (value === undefined) throw new Error(`Missing value for ${token}`);
      flags.set(token, value);
      continue;
    }
    if (token.startsWith("--")) throw new Error(`Unknown crm option: ${token}`);
    positional.push(token);
  }
  const dir = flags.get("--dir");
  if (!dir) throw new Error("Required: --dir CORPUS");
  const now = flags.has("--now") ? new Date(flags.get("--now")!) : undefined;
  if (now && !Number.isFinite(now.getTime())) throw new Error("--now must be an ISO timestamp");
  const number = (key: string) => {
    if (!flags.has(key)) return undefined;
    const value = Number(flags.get(key));
    if (!Number.isFinite(value)) throw new Error(`${key} must be a number`);
    return value;
  };
  const list = (key: string) => flags.get(key)?.split(",").map((item) => item.trim()).filter(Boolean);
  const apply = booleans.has("--apply");
  const ref = () => {
    if (!positional[0]) throw new Error(`crm ${action} requires a person or company reference`);
    return positional.join(" ");
  };
  let result: unknown;
  switch (action) {
    case "list": {
      const kind = flags.get("--kind");
      if (kind && kind !== "people" && kind !== "companies") throw new Error("--kind must be people or companies");
      result = crmIndex(dir, { now, kind: kind as "people" | "companies" | undefined, stage: flags.get("--stage"), query: flags.get("--query"), limit: number("--limit"), details: booleans.has("--details"), days: number("--days") });
      break;
    }
    case "warm": result = crmWarm(dir, { now, rebuild: booleans.has("--rebuild") }); break;
    case "show": result = crmShow(dir, ref(), { now, days: number("--days") }); break;
    case "resolve": result = crmResolve(dir, ref(), { now }); break;
    case "set": {
      const field = flags.get("--field");
      if (!field || !flags.has("--value")) throw new Error("crm set requires --field and --value");
      result = crmSet(dir, ref(), field, flags.get("--value")!, { now, apply, expectedRevision: flags.get("--if-revision") });
      break;
    }
    case "follow-up":
      result = crmFollowUp(dir, ref(), { title: flags.get("--title") || "", scheduled: flags.get("--scheduled"), deadline: flags.get("--deadline"), priority: flags.get("--priority") }, { now, apply, expectedRevision: flags.get("--if-revision") });
      break;
    case "create": {
      const kind = positional[0];
      if (!kind) throw new Error("crm create requires person or company");
      result = crmCreate(dir, kind, { title: flags.get("--title"), domain: flags.get("--domain"), email: flags.get("--email"), role: flags.get("--role"), stage: flags.get("--stage"), company: flags.get("--company"), fromLedger: flags.get("--from-ledger") }, { now, apply });
      break;
    }
    case "link": result = crmLink(dir, { now, apply, only: list("--only") }); break;
    case "upcoming": result = crmUpcoming(dir, { now, days: number("--days") }); break;
    case "schedule":
      result = crmSchedule(dir, { now, apply, days: number("--days"), hours: flags.get("--hours"), duration: number("--duration"), only: list("--only"), weekends: booleans.has("--weekends"), overdueDays: number("--overdue-days") });
      break;
    default:
      throw new Error("Expected crm list, warm, show, resolve, set, follow-up, create, link, upcoming or schedule");
  }
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
}
