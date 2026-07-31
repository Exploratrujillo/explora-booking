import { dateKey, formatDate, startOfMonth, startOfWeek } from '../lib/dates'
import { DepartureCard } from './DepartureCard'

export function MonthView({ anchor, departures, onOpen }) {
  const first = startOfWeek(startOfMonth(anchor))
  const days = Array.from({ length: 42 }, (_, index) => {
    const day = new Date(first)
    day.setDate(day.getDate() + index)
    return day
  })

  const grouped = departures.reduce((acc, departure) => {
    const key = dateKey(departure.starts_at)
    acc[key] ||= []
    acc[key].push(departure)
    return acc
  }, {})

  return (
    <section className="month-grid">
      {['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'].map((day) => (
        <div className="weekday" key={day}>{day}</div>
      ))}

      {days.map((day) => {
        const key = dateKey(day)
        const outside = day.getMonth() !== anchor.getMonth()

        return (
          <article
            className={`month-day ${outside ? 'outside' : ''}`}
            key={key}
          >
            <header>
              <span>{formatDate(day, { day: 'numeric' })}</span>
            </header>

            <div className="day-events">
              {(grouped[key] || []).map((departure) => (
                <DepartureCard
                  key={departure.id}
                  departure={departure}
                  onOpen={onOpen}
                />
              ))}
            </div>
          </article>
        )
      })}
    </section>
  )
}
