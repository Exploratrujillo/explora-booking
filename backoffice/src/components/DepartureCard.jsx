import { formatTime } from '../lib/dates'

const STATUS_LABELS = {
  scheduled: 'Programada',
  cancelled: 'Cancelada',
  completed: 'Finalizada',
}

export function DepartureCard({ departure, onOpen }) {
  return (
    <button
      type="button"
      className={`departure-card status-${departure.status}`}
      onClick={() => onOpen(departure)}
    >
      <strong>{formatTime(departure.starts_at)}</strong>
      <span>{departure.experience_name}</span>
      <small>{departure.guide_name || 'Sin guía asignada'}</small>
      <em>{STATUS_LABELS[departure.status] || departure.status}</em>
    </button>
  )
}
