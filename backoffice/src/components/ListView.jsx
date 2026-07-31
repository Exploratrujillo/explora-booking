import {
  dateKey,
  formatDate,
  startOfDay,
  startOfWeek,
} from '../lib/dates'
import { DepartureCard } from './DepartureCard'

export function ListView({ anchor, view, departures, onOpen }) {
  const start = view === 'day' ? startOfDay(anchor) : startOfWeek(anchor)
  const count = view === 'day' ? 1 : 7

  const days = Array.from({ length: count }, (_, index) => {
    const day = new Date(start)
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
    <section className={`list-view ${view}`}>
      {days.map((day) => {
        const key = dateKey(day)
        const items = grouped[key] || []

        return (
          <article className="list-day" key={key}>
            <header>
              <strong>{formatDate(day, { weekday: 'long' })}</strong>
              <span>{formatDate(day, {
                day: 'numeric',
                month: 'long',
              })}</span>
            </header>

            <div className="list-events">
              {items.length ? (
                items.map((departure) => (
                  <DepartureCard
                    key={departure.id}
                    departure={departure}
                    onOpen={onOpen}
                  />
                ))
              ) : (
                <p className="empty">Sin salidas</p>
              )}
            </div>
          </article>
        )
      })}
    </section>
  )
}
