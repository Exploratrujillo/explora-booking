import { addPeriod, formatDate } from '../lib/dates'

export function CalendarToolbar({
  anchor,
  setAnchor,
  view,
  setView,
  onCreate,
  onPlan,
}) {
  const title =
    view === 'day'
      ? formatDate(anchor, {
          weekday: 'long',
          day: 'numeric',
          month: 'long',
          year: 'numeric',
        })
      : view === 'week'
        ? `Semana del ${formatDate(anchor, {
            day: 'numeric',
            month: 'long',
          })}`
        : formatDate(anchor, {
            month: 'long',
            year: 'numeric',
          })

  return (
    <section className="toolbar">
      <div>
        <p className="eyebrow">CALENDARIO OPERATIVO</p>
        <h2 className="calendar-title">{title}</h2>
      </div>

      <div className="toolbar-actions">
        <button className="secondary" onClick={() => setAnchor(new Date())}>
          Hoy
        </button>
        <button
          className="icon-button"
          aria-label="Periodo anterior"
          onClick={() => setAnchor(addPeriod(anchor, view, -1))}
        >
          ‹
        </button>
        <button
          className="icon-button"
          aria-label="Periodo siguiente"
          onClick={() => setAnchor(addPeriod(anchor, view, 1))}
        >
          ›
        </button>

        <div className="segmented">
          {[
            ['month', 'Mes'],
            ['week', 'Semana'],
            ['day', 'Día'],
          ].map(([value, label]) => (
            <button
              key={value}
              className={view === value ? 'active' : ''}
              onClick={() => setView(value)}
            >
              {label}
            </button>
          ))}
        </div>

        {onPlan && <button onClick={onPlan}>Generar por bloque</button>}
        {onCreate && <button className="secondary" onClick={onCreate}>+ Salida manual</button>}
      </div>
    </section>
  )
}
