import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { endExclusiveForView } from '../lib/dates'
import { CalendarToolbar } from './CalendarToolbar'
import { MonthView } from './MonthView'
import { ListView } from './ListView'
import { CreateDepartureModal } from './CreateDepartureModal'
import { DepartureModal } from './DepartureModal'
import { ScheduleBlockModal } from './ScheduleBlockModal'

export function Backoffice({ profile }) {
  const [section, setSection] = useState('agenda')
  const [anchor, setAnchor] = useState(new Date())
  const [view, setView] = useState('month')
  const [departures, setDepartures] = useState([])
  const [experiences, setExperiences] = useState([])
  const [guides, setGuides] = useState([])
  const [experienceId, setExperienceId] = useState('')
  const [loading, setLoading] = useState(true)
  const [message, setMessage] = useState('')
  const [creating, setCreating] = useState(false)
  const [planning, setPlanning] = useState(false)
  const [selected, setSelected] = useState(null)

  const range = useMemo(
    () => endExclusiveForView(anchor, view),
    [anchor, view]
  )

  const loadCatalogues = useCallback(async () => {
    const [experiencesResult, guidesResult] = await Promise.all([
      supabase.rpc('list_backoffice_experiences'),
      supabase.rpc('list_active_guides'),
    ])

    if (experiencesResult.error || guidesResult.error) {
      setMessage(
        experiencesResult.error?.message ||
        guidesResult.error?.message ||
        'No se pudieron cargar los catálogos.'
      )
      return
    }

    const catalogue = experiencesResult.data || []
    setExperiences(catalogue)
    setGuides(guidesResult.data || [])
    setExperienceId((current) => current || catalogue[0]?.id || '')
  }, [])

  const loadDepartures = useCallback(async () => {
    setLoading(true)
    setMessage('')

    const rpcName = section === 'agenda'
      ? 'list_agenda_departures'
      : 'list_operational_departures'

    const params = {
      p_from: range.start.toISOString(),
      p_until: range.end.toISOString(),
    }

    if (section === 'operations') {
      params.p_experience_id = experienceId || null
    }

    const { data, error } = await supabase.rpc(rpcName, params)

    if (error) {
      setMessage(error.message)
    } else {
      setDepartures(data || [])
      setSelected((current) => {
        if (!current) return null
        return (data || []).find((item) => item.id === current.id) || null
      })
    }

    setLoading(false)
  }, [section, experienceId, range.start.getTime(), range.end.getTime()])

  useEffect(() => {
    loadCatalogues()
  }, [loadCatalogues])

  useEffect(() => {
    loadDepartures()
  }, [loadDepartures])

  async function signOut() {
    await supabase.auth.signOut()
  }

  return (
    <main className="app-shell">
      <aside className="sidebar">
        <div>
          <div className="brand-mark">ET</div>
          <p className="brand-name">Explora Trujillo</p>
          <span className="brand-subtitle">Gestión</span>
        </div>

        <nav>
          <button
            className={`nav-item ${section === 'agenda' ? 'active' : ''}`}
            onClick={() => setSection('agenda')}
          >
            Agenda
          </button>
          <button
            className={`nav-item ${section === 'operations' ? 'active' : ''}`}
            onClick={() => setSection('operations')}
          >
            Operativa por producto
          </button>
          <button className="nav-item" disabled>Reservas</button>
          <button className="nav-item" disabled>Clientes</button>
          <button className="nav-item" disabled>Check-in</button>
        </nav>

        <div className="sidebar-user">
          <strong>{profile.display_name || profile.full_name}</strong>
          <span>{profile.role}</span>
          <button className="secondary" onClick={signOut}>
            Cerrar sesión
          </button>
        </div>
      </aside>

      <section className="main-panel">
        <div className="section-heading">
          <div>
            <p className="eyebrow">
              {section === 'agenda' ? 'OPERACIÓN DIARIA' : 'PLANIFICACIÓN COMERCIAL'}
            </p>
            <h1>{section === 'agenda' ? 'Agenda' : 'Operativa por producto'}</h1>
            <p className="muted section-description">
              {section === 'agenda'
                ? 'Aquí aparecerán las salidas con reservas y los eventos internos.'
                : 'Gestiona todas las salidas programadas de cada experiencia.'}
            </p>
          </div>

          {section === 'operations' && (
            <label className="experience-filter">
              Experiencia
              <select
                value={experienceId}
                onChange={(event) => setExperienceId(event.target.value)}
              >
                {experiences.map((experience) => (
                  <option key={experience.id} value={experience.id}>
                    {experience.name}
                  </option>
                ))}
              </select>
            </label>
          )}
        </div>

        <CalendarToolbar
          anchor={anchor}
          setAnchor={setAnchor}
          view={view}
          setView={setView}
          onCreate={section === 'operations' ? () => setCreating(true) : undefined}
          onPlan={section === 'operations' ? () => setPlanning(true) : undefined}
        />

        {message && <p className="message error">{message}</p>}

        {loading ? (
          <div className="loading-card">Cargando calendario…</div>
        ) : departures.length === 0 ? (
          <div className="empty-state">
            <strong>
              {section === 'agenda'
                ? 'No hay actividad en este periodo'
                : 'No hay salidas para esta experiencia'}
            </strong>
            <span>
              {section === 'agenda'
                ? 'Las salidas comerciales aparecerán cuando reciban su primera reserva.'
                : 'Puedes crear una salida manual desde el botón superior.'}
            </span>
          </div>
        ) : view === 'month' ? (
          <MonthView
            anchor={anchor}
            departures={departures}
            onOpen={setSelected}
          />
        ) : (
          <ListView
            anchor={anchor}
            view={view}
            departures={departures}
            onOpen={setSelected}
          />
        )}
      </section>

      <ScheduleBlockModal
        open={planning}
        onClose={() => setPlanning(false)}
        experiences={experiences}
        guides={guides}
        defaultExperienceId={experienceId}
        anchor={anchor}
        onGenerated={loadDepartures}
      />

      <CreateDepartureModal
        open={creating}
        onClose={() => setCreating(false)}
        experiences={experiences}
        guides={guides}
        anchor={anchor}
        onCreated={loadDepartures}
      />

      <DepartureModal
        departure={selected}
        guides={guides}
        onClose={() => setSelected(null)}
        onChanged={loadDepartures}
      />
    </main>
  )
}
