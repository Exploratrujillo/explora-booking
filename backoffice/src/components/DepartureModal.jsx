import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { dateKey, formatDate, formatTime } from '../lib/dates'

export function DepartureModal({
  departure,
  guides,
  onClose,
  onChanged,
}) {
  const [date, setDate] = useState('')
  const [time, setTime] = useState('')
  const [guideId, setGuideId] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    if (!departure) return
    setDate(dateKey(departure.starts_at))
    setTime(formatTime(departure.starts_at))
    setGuideId(departure.guide_profile_id || '')
    setError('')
  }, [departure])

  if (!departure) return null

  async function run(action) {
    setBusy(true)
    setError('')

    const result = await action()
    setBusy(false)

    if (result.error) {
      setError(result.error.message)
      return false
    }

    onChanged()
    return true
  }

  async function move() {
    await run(() =>
      supabase.rpc('move_departure', {
        p_departure_id: departure.id,
        p_starts_at: new Date(`${date}T${time}:00`).toISOString(),
      })
    )
  }

  async function assignGuide() {
    if (!guideId) {
      setError('Selecciona una guía.')
      return
    }

    await run(() =>
      supabase.rpc('assign_departure_guide', {
        p_departure_id: departure.id,
        p_guide_profile_id: guideId,
      })
    )
  }

  async function status(nextStatus) {
    const ok = await run(() =>
      supabase.rpc('set_departure_status', {
        p_departure_id: departure.id,
        p_status: nextStatus,
      })
    )
    if (ok) onClose()
  }

  return (
    <div className="modal-backdrop" role="presentation">
      <section className="modal" role="dialog" aria-modal="true">
        <header className="modal-header">
          <div>
            <p className="eyebrow">{departure.experience_code}</p>
            <h2>{departure.experience_name}</h2>
            <p className="muted">
              {formatDate(new Date(departure.starts_at), {
                weekday: 'long',
                day: 'numeric',
                month: 'long',
              })}{' '}
              · {formatTime(departure.starts_at)}
            </p>
          </div>
          <button className="icon-button" onClick={onClose}>×</button>
        </header>

        <div className="details-grid">
          <div><span>Estado</span><strong>{departure.status}</strong></div>
          <div><span>Capacidad</span><strong>{departure.capacity}</strong></div>
          <div><span>Guía</span><strong>{departure.guide_name || 'Sin asignar'}</strong></div>
          <div><span>Origen</span><strong>{departure.is_manual ? 'Manual' : 'Programación'}</strong></div>
        </div>

        <section className="edit-section">
          <h3>Cambiar fecha y hora</h3>
          <div className="form-row">
            <input
              type="date"
              value={date}
              onChange={(event) => setDate(event.target.value)}
            />
            <input
              type="time"
              value={time}
              onChange={(event) => setTime(event.target.value)}
            />
          </div>
          <button className="secondary" onClick={move} disabled={busy}>
            Guardar nuevo horario
          </button>
        </section>

        <section className="edit-section">
          <h3>Asignar guía</h3>
          <div className="inline-form">
            <select value={guideId} onChange={(event) => setGuideId(event.target.value)}>
              <option value="">Seleccionar</option>
              {guides.map((guide) => (
                <option key={guide.resource_id} value={guide.profile_id}>
                  {guide.name}
                </option>
              ))}
            </select>
            <button className="secondary" onClick={assignGuide} disabled={busy}>
              Asignar
            </button>
          </div>
        </section>

        {error && <p className="message error">{error}</p>}

        <footer className="modal-actions split">
          <button
            className="danger"
            disabled={busy}
            onClick={() => status('cancelled')}
          >
            Cancelar salida
          </button>
          <button
            disabled={busy}
            onClick={() => status('scheduled')}
          >
            Marcar programada
          </button>
        </footer>
      </section>
    </div>
  )
}
