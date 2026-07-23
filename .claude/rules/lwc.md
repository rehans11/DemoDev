# RULE: Lightning Web Components (and Aura) — MANDATORY

Applies to files under `force-app/**/lwc/**` and `force-app/**/aura/**`. Adhere strictly.
Prefer **LWC** for all new UI; only touch Aura to maintain existing components.

## Structure & naming
- camelCase folder/JS name; PascalCase class. Follow `naming-conventions.md`.
- Keep components small and single-purpose. Split container (data) vs presentational
  (UI) components. Expose a clean `@api` public interface; document each public prop.
- `*.js-meta.xml`: set `apiVersion` 61.0, `isExposed`, and correct `targets`/`targetConfigs`.

## Data access
- Prefer `@wire` to cacheable Apex or LDS (`getRecord`, `getObjectInfo`, `uiRecordApi`)
  for reads; use imperative Apex for user-triggered actions/writes.
- Apex methods for `@wire` must be `@AuraEnabled(cacheable=true)` and side-effect free.
- Handle **loading, empty, and error** states explicitly. Surface errors via toast /
  inline message from `error` — never swallow.
- Never build SOQL from unsanitized client input in Apex called by LWC.

## Reactivity & performance
- Use getters over expensive expressions in templates; avoid heavy work in `renderedCallback`.
- Don't mutate `@wire` results or `@api` props directly; treat as immutable.
- Debounce user-driven server calls. Use `refreshApex` to refresh wired data after DML.
- Lazy-load and paginate large lists; avoid rendering thousands of rows.

## Events & communication
- Child→parent via `CustomEvent` (lowercase, no colon); parent→child via `@api`.
- Cross-DOM via Lightning Message Service (LMS), not global window events.
- Use `@salesforce/*` scoped modules for labels, resources, schema (import fields via
  `@salesforce/schema/...` — never hardcode field API name strings).

## Security & UX (see security.md)
- Enforce CRUD/FLS in the Apex controller; the UI is not a security boundary.
- No secrets in JS. Escape/trust nothing from the client.
- **Accessibility:** semantic HTML, labels for inputs, keyboard nav, aria attributes,
  SLDS components. Meet WCAG AA.
- Use SLDS for styling; avoid inline styles and `lwc:dom="manual"` unless necessary.

## Testing
- Jest tests (`sfdx-lwc-jest`) for components: rendering, events, wired data (mocked),
  and error paths. Run `npm run test:unit`.
