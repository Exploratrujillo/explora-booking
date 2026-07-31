import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'

const WEEKDAYS = [
  [1, 'Lunes'],
  [2, 'Martes'],
  [3, 'Miércoles'],
  [4, 'Jueves'],
  [5, 'Viernes'],
  [6, 'Sábado'],
  [7, 'Domingo'],
]

const MONTHS = [
  'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
]

function parseLocalDate(value) {
  if (!value) return null
  const [year, month, day] = value.split('-').map(Number)
  return new Date(year, month - 1, day)
}

function formatDisplayDate(value) {
  const date = parseLocalDate(value)
  if (!date) return '—'
  return new Intl.DateTimeFormat('es-ES', {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  }).format(date)
}


function buildCandidateDates(validFrom, validUntil, weekdays, times) {
  const start = parseLocalDate(validFrom)
  const end = parseLocalDate(validUntil)
  if (!start || !end || start > end) return []

  const selectedDays = new Set(weekdays)
  const uniqueTimes = [...new Set(times.filter(Boolean))].sort()
  const dates = []

  for (const current = new Date(start); current <= end; current.setDate(current.getDate() + 1)) {
    const isoWeekday = current.getDay() === 0 ? 7 : current.getDay()
    if (!selectedDays.has(isoWeekday)) continue

    uniqueTimes.forEach((time) => {
      dates.push({ date: new Date(current), time })
    })
  }

  return dates
}

function formatCandidateDate(item) {
  const day = new Intl.DateTimeFormat('es-ES', {
    weekday: 'short',
    day: '2-digit',
    month: '2-digit',
  }).format(item.date)

  return `${day.replace('.', '')} · ${item.time}`
}

function buildBlockName(experienceName, validFrom, validUntil) {
  const from = parseLocalDate(validFrom)
  const until = parseLocalDate(validUntil)
  if (!from || !until) return experienceName || 'Planificación'

  const sameYear = from.getFullYear() === until.getFullYear()
  const period = from.getMonth() === until.getMonth()
    ? MONTHS[from.getMonth()]
    : `${MONTHS[from.getMonth()]}–${MONTHS[until.getMonth()]}`
  const year = sameYear
    ? from.getFullYear()
    : `${from.getFullYear()}–${until.getFullYear()}`

  return `${experienceName || 'Planificación'} · ${period} ${year}`
}

function initialForm(experience, guide, anchor) {
  const year = anchor.getFullYear()
  const validFrom = `${year}-01-01`
  const validUntil = `${year}-12-31`

  return {
    experienceId: experience?.id || '',
    name: buildBlockName(experience?.name, validFrom, validUntil),
    validFrom,
    validUntil,
    weekdays: [1, 2, 3, 4, 5],
    times: ['11:30'],
    capacity: experience?.default_capacity ?? '',
    minimumAdults: experience?.minimum_adults ?? '',
    guideProfileId: guide?.profile_id || '',
  }
}

export function ScheduleBlockModal({
  open,
  onClose,
  experiences,
  guides,
  defaultExperienceId,
  anchor,
  onGenerated,
}) {
  const defaultExperience = useMemo(
    () => experiences.find((item) => item.id === defaultExperienceId) || experiences[0],
    [experiences, defaultExperienceId]
  )

  const [form, setForm] = useState(() => initialForm(defaultExperience, guides[0], anchor))
  const [nameEdited, setNameEdited] = useState(false)
  const [step, setStep] = useState('form')
  const [preview, setPreview] = useState(null)
  const [result, setResult] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    if (!open) return
    setForm(initialForm(defaultExperience, guides[0], anchor))
    setNameEdited(false)
    setStep('form')
    setPreview(null)
    setResult(null)
    setError('')
  }, [open, defaultExperience?.id, guides, anchor])

  function selectedExperience() {
    return experiences.find((item) => item.id === form.experienceId)
  }

  function updatePeriod(field, value) {
    setForm((current) => {
      const next = { ...current, [field]: value }
      if (!nameEdited) {
        const experience = experiences.find((item) => item.id === next.experienceId)
        next.name = buildBlockName(experience?.name, next.validFrom, next.validUntil)
      }
      return next
    })
  }

  function changeExperience(experienceId) {
    const experience = experiences.find((item) => item.id === experienceId)
    setForm((current) => ({
      ...current,
      experienceId,
      name: nameEdited
        ? current.name
        : buildBlockName(experience?.name, current.validFrom, current.validUntil),
      capacity: experience?.default_capacity ?? '',
      minimumAdults: experience?.minimum_adults ?? '',
    }))
  }

  function toggleWeekday(value) {
    setForm((current) => ({
      ...current,
      weekdays: current.weekdays.includes(value)
        ? current.weekdays.filter((day) => day !== value)
        : [...current.weekdays, value].sort(),
    }))
  }

  function changeTime(index, value) {
    setForm((current) => ({
      ...current,
      times: current.times.map((time, itemIndex) => itemIndex === index ? value : time),
    }))
  }

  function addTime() {
    setForm((current) => ({ ...current, times: [...current.times, ''] }))
  }

  function removeTime(index) {
    if (index === 0) return
    setForm((current) => ({
      ...current,
      times: current.times.filter((_, itemIndex) => itemIndex !== index),
    }))
  }

  async function createPreview(event) {
    event.preventDefault()
    setBusy(true)
    setError('')

    const times = [...new Set(form.times.filter(Boolean))].sort()
    if (form.weekdays.length === 0) {
      setError('Selecciona al menos un día de la semana.')
      setBusy(false)
      return
    }
    if (times.length === 0) {
      setError('Indica al menos una hora.')
      setBusy(false)
      return
    }

    const { data, error: rpcError } = await supabase.rpc(
      'create_schedule_block_draft',
      {
        p_experience_id: form.experienceId,
        p_name: form.name,
        p_valid_from: form.validFrom,
        p_valid_until: form.validUntil,
        p_weekdays: form.weekdays,
        p_times: times,
        p_capacity: form.capacity === '' ? null : Number(form.capacity),
        p_minimum_adults: form.minimumAdults === '' ? null : Number(form.minimumAdults),
        p_guide_profile_id: form.guideProfileId || null,
      }
    )

    setBusy(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }

    setPreview(data?.[0] || null)
    setStep('preview')
  }

  async function discardDraft() {
    if (preview?.schedule_id && !result) {
      await supabase.rpc('discard_schedule_block_draft', {
        p_schedule_id: preview.schedule_id,
      })
    }
  }

  async function backToForm() {
    setBusy(true)
    await discardDraft()
    setPreview(null)
    setStep('form')
    setBusy(false)
  }

  async function closeModal() {
    await discardDraft()
    onClose()
  }

  async function generate() {
    if (!preview?.schedule_id) return
    setBusy(true)
    setError('')

    const { data, error: rpcError } = await supabase.rpc(
      'activate_and_generate_schedule_block',
      { p_schedule_id: preview.schedule_id }
    )

    setBusy(false)
    if (rpcError) {
      setError(rpcError.message)
      return
    }

    setResult(data?.[0] || null)
    setStep('result')
    onGenerated()
  }

  if (!open) return null

  const experience = selectedExperience()
  const guide = guides.find((item) => item.profile_id === form.guideProfileId)
  const actualCreationCount = preview
    ? Math.max(0, preview.candidate_count - preview.existing_count - preview.conflict_count)
    : 0
  const candidateDates = buildCandidateDates(form.validFrom, form.validUntil, form.weekdays, form.times)
  const sampleDates = candidateDates.slice(0, 8)
  const remainingSampleCount = Math.max(0, candidateDates.length - sampleDates.length)

  return (
    <div className="modal-backdrop" role="presentation">
      <section className="modal schedule-modal" role="dialog" aria-modal="true">
        <header className="modal-header">
          <div>
            <p className="eyebrow">PLANIFICACIÓN POR BLOQUES</p>
            <h2>
              {step === 'form' && 'Nuevo bloque de salidas'}
              {step === 'preview' && 'Resumen del bloque'}
              {step === 'result' && 'Salidas generadas'}
            </h2>
          </div>
          <button className="icon-button" onClick={closeModal} aria-label="Cerrar">×</button>
        </header>

        {step === 'form' && (
          <form onSubmit={createPreview}>
            <label>
              Experiencia
              <select value={form.experienceId} onChange={(event) => changeExperience(event.target.value)} required>
                {experiences.map((item) => (
                  <option key={item.id} value={item.id}>{item.name}</option>
                ))}
              </select>
            </label>

            <label>
              Nombre interno del bloque
              <input
                value={form.name}
                onChange={(event) => {
                  setNameEdited(true)
                  setForm({ ...form, name: event.target.value })
                }}
                required
              />
              <small className="field-help">Se genera automáticamente, pero puedes editarlo.</small>
            </label>

            <div className="form-row">
              <label>
                Desde
                <input
                  type="date"
                  value={form.validFrom}
                  onChange={(event) => updatePeriod('validFrom', event.target.value)}
                  required
                />
              </label>
              <label>
                Hasta
                <input
                  type="date"
                  value={form.validUntil}
                  min={form.validFrom}
                  onChange={(event) => updatePeriod('validUntil', event.target.value)}
                  required
                />
              </label>
            </div>

            <fieldset className="weekday-fieldset">
              <legend>Días de la semana</legend>
              <div className="weekday-options">
                {WEEKDAYS.map(([value, label]) => (
                  <label className="weekday-option" key={value}>
                    <input
                      type="checkbox"
                      checked={form.weekdays.includes(value)}
                      onChange={() => toggleWeekday(value)}
                    />
                    <span>{label}</span>
                  </label>
                ))}
              </div>
            </fieldset>

            <fieldset className="times-fieldset">
              <legend>Horarios</legend>
              <div className="time-list">
                {form.times.map((time, index) => (
                  <div className="time-row" key={index}>
                    <input
                      type="time"
                      value={time}
                      onChange={(event) => changeTime(index, event.target.value)}
                      required
                    />
                    {index > 0 && (
                      <button type="button" className="secondary" onClick={() => removeTime(index)}>
                        Quitar
                      </button>
                    )}
                  </div>
                ))}
              </div>
              <button type="button" className="text-button" onClick={addTime}>+ Añadir horario</button>
            </fieldset>

            <div className="form-row">
              <label>
                Capacidad por salida
                <input
                  type="number"
                  min="1"
                  value={form.capacity}
                  onChange={(event) => setForm({ ...form, capacity: event.target.value })}
                  required
                />
                <small className="field-help">Heredada de la experiencia. Puedes cambiarla para este bloque.</small>
              </label>
              <label>
                Mínimo de adultos
                <input
                  type="number"
                  min="0"
                  value={form.minimumAdults}
                  onChange={(event) => setForm({ ...form, minimumAdults: event.target.value })}
                  required
                />
                <small className="field-help">Heredado de la experiencia.</small>
              </label>
            </div>

            <label>
              Guía predeterminada
              <select
                value={form.guideProfileId}
                onChange={(event) => setForm({ ...form, guideProfileId: event.target.value })}
              >
                <option value="">Sin asignar</option>
                {guides.map((item) => (
                  <option key={item.resource_id} value={item.profile_id}>{item.name}</option>
                ))}
              </select>
            </label>

            {error && <p className="message error">{error}</p>}

            <footer className="modal-actions">
              <button type="button" className="secondary" onClick={closeModal}>Cancelar</button>
              <button disabled={busy}>{busy ? 'Calculando…' : 'Continuar'}</button>
            </footer>
          </form>
        )}

        {step === 'preview' && preview && (
          <div className="schedule-summary">
            <div className="block-heading">
              <strong>{experience?.name}</strong>
              <span>{form.name}</span>
            </div>

            <dl className="summary-details">
              <div><dt>Periodo</dt><dd>{formatDisplayDate(form.validFrom)} – {formatDisplayDate(form.validUntil)}</dd></div>
              <div><dt>Días</dt><dd>{WEEKDAYS.filter(([value]) => form.weekdays.includes(value)).map(([, label]) => label).join(', ')}</dd></div>
              <div><dt>Horario</dt><dd>{form.times.filter(Boolean).join(', ')}</dd></div>
              <div><dt>Capacidad</dt><dd>{form.capacity}</dd></div>
              <div><dt>Mínimo de adultos</dt><dd>{form.minimumAdults}</dd></div>
              <div><dt>Guía</dt><dd>{guide?.name || 'Sin asignar'}</dd></div>
            </dl>

            <div className="summary-cards">
              <div><strong>{preview.candidate_count}</strong><span>salidas previstas</span></div>
              <div><strong>{preview.existing_count}</strong><span>ya existen</span></div>
              <div className="summary-card-primary"><strong>{actualCreationCount}</strong><span>se crearán</span></div>
            </div>

            <section className="preview-dates" aria-label="Muestra de fechas">
              <div className="preview-dates-heading">
                <strong>Fechas calculadas</strong>
                <span>Muestra previa antes de crear las salidas</span>
              </div>
              <ul>
                {sampleDates.map((item, index) => (
                  <li key={`${item.date.toISOString()}-${item.time}-${index}`}>
                    {formatCandidateDate(item)}
                  </li>
                ))}
              </ul>
              {remainingSampleCount > 0 && (
                <p>+ {remainingSampleCount} {remainingSampleCount === 1 ? 'salida más' : 'salidas más'}</p>
              )}
            </section>

            {preview.conflict_count === 0 ? (
              <p className="message success">✓ No se han detectado conflictos de guía.</p>
            ) : (
              <p className="message warning">
                Hay {preview.conflict_count} {preview.conflict_count === 1 ? 'conflicto de guía' : 'conflictos de guía'}. Esas fechas se omitirán; el resto se generará normalmente.
              </p>
            )}

            {preview.existing_count > 0 && (
              <p className="message warning">
                {preview.existing_count} {preview.existing_count === 1 ? 'salida ya existe' : 'salidas ya existen'} y no se duplicarán.
              </p>
            )}
            {error && <p className="message error">{error}</p>}

            <footer className="modal-actions split">
              <button type="button" className="secondary" onClick={backToForm} disabled={busy}>← Volver</button>
              <button onClick={generate} disabled={busy || actualCreationCount === 0}>
                {busy
                  ? `Creando ${actualCreationCount} ${actualCreationCount === 1 ? 'salida' : 'salidas'}…`
                  : `Crear ${actualCreationCount} ${actualCreationCount === 1 ? 'salida' : 'salidas'}`}
              </button>
            </footer>
          </div>
        )}

        {step === 'result' && result && (
          <div className="schedule-summary">
            <p className="success-title">El bloque se ha activado correctamente.</p>
            <div className="summary-cards">
              <div><strong>{result.inserted_count}</strong><span>salidas creadas</span></div>
              <div><strong>{result.skipped_existing_count}</strong><span>existentes omitidas</span></div>
              <div><strong>{result.conflict_count}</strong><span>conflictos omitidos</span></div>
            </div>
            <footer className="modal-actions">
              <button onClick={onClose}>Cerrar</button>
            </footer>
          </div>
        )}
      </section>
    </div>
  )
}
