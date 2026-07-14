const tokenPattern = /\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}/g;

function readPath(payload: Record<string, unknown>, path: string) {
  return path.split(".").reduce<unknown>((value, key) => {
    if (value && typeof value === "object" && key in value) {
      return (value as Record<string, unknown>)[key];
    }
    return undefined;
  }, payload);
}

export function renderTemplate(template: string, payload: Record<string, unknown>) {
  return template.replace(tokenPattern, (_, key: string) => {
    const value = readPath(payload, key);
    return value === undefined || value === null ? "" : String(value);
  });
}
