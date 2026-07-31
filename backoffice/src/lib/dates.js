export const TZ = 'Europe/Madrid'

export function startOfDay(date) {
  const copy = new Date(date)
  copy.setHours(0, 0, 0, 0)
  return copy
}

export function startOfWeek(date) {
  const copy = startOfDay(date)
  const day = copy.getDay() || 7
  copy.setDate(copy.getDate() - day + 1)
  return copy
}

export function startOfMonth(date) {
  return new Date(date.getFullYear(), date.getMonth(), 1)
}

export function endExclusiveForView(anchor, view) {
  const start =
    view === 'day'
      ? startOfDay(anchor)
      : view === 'week'
        ? startOfWeek(anchor)
        : startOfWeek(startOfMonth(anchor))

  const end = new Date(start)
  if (view === 'day') end.setDate(end.getDate() + 1)
  if (view === 'week') end.setDate(end.getDate() + 7)
  if (view === 'month') end.setDate(end.getDate() + 42)

  return { start, end }
}

export function addPeriod(anchor, view, amount) {
  const date = new Date(anchor)
  if (view === 'day') date.setDate(date.getDate() + amount)
  if (view === 'week') date.setDate(date.getDate() + amount * 7)
  if (view === 'month') date.setMonth(date.getMonth() + amount)
  return date
}

export function formatDate(date, options = {}) {
  return new Intl.DateTimeFormat('es-ES', {
    timeZone: TZ,
    ...options,
  }).format(date)
}

export function formatTime(value) {
  return formatDate(new Date(value), {
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function dateKey(value) {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date(value))
}

export function toMadridIso(dateText, timeText) {
  // En 2026 el navegador convierte la fecha local del usuario.
  // El proyecto se usa operativamente en España.
  const local = new Date(`${dateText}T${timeText}:00`)
  return local.toISOString()
}
