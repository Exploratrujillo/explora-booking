export const products = [
  {
    id: "esencial",
    name: "Trujillo Esencial",
    eyebrow: "La visita imprescindible",
    duration: "2 horas",
    meetingPoint: "Plaza Mayor",
    priceAdult: 9.5,
    priceChild: 0,
    childLabel: "Niños hasta 12 años gratis",
    capacity: 25,
    minimumAdults: 4,
    inventoryRule: "adults-only",
    description:
      "Descubre la Plaza Mayor, el casco histórico y los grandes personajes de Trujillo con una guía oficial.",
    dates: [
      { date: "2026-10-03", time: "10:30", status: "available", remaining: 18 },
      { date: "2026-10-04", time: "10:30", status: "available", remaining: 7 },
      { date: "2026-10-10", time: "10:30", status: "full", remaining: 0 },
      { date: "2026-10-11", time: "10:30", status: "available", remaining: 13 },
    ],
  },
  {
    id: "candil",
    name: "A la luz del Candil",
    eyebrow: "Experiencia nocturna",
    duration: "1 hora y 30 minutos",
    meetingPoint: "Plaza Mayor",
    priceAdult: 10,
    priceChild: null,
    childLabel: "Actividad para mayores de 12 años",
    capacity: 25,
    minimumAdults: 4,
    inventoryRule: "adults-only",
    description:
      "Un recorrido nocturno por las historias, leyendas y rincones más evocadores de Trujillo.",
    dates: [
      { date: "2026-10-03", time: "20:30", status: "available", remaining: 14 },
      { date: "2026-10-09", time: "20:30", status: "available", remaining: 20 },
      { date: "2026-10-10", time: "20:30", status: "full", remaining: 0 },
    ],
  },
  {
    id: "exploradores",
    name: "Pequeños Exploradores",
    eyebrow: "Trujillo en familia",
    duration: "2 horas",
    meetingPoint: "Plaza Mayor",
    priceAdult: 10,
    priceChild: 6,
    childLabel: "Niños de 4 a 14 años · menores de 3 gratis",
    capacity: 25,
    minimumAdults: 4,
    inventoryRule: "all-except-babies",
    description:
      "Una visita dinámica para familias, con pruebas, historias y retos adaptados a los más pequeños.",
    dates: [
      { date: "2026-10-04", time: "11:00", status: "available", remaining: 16 },
      { date: "2026-10-11", time: "11:00", status: "available", remaining: 8 },
      { date: "2026-10-12", time: "11:00", status: "full", remaining: 0 },
    ],
  },
  {
    id: "privada",
    name: "Visita privada",
    eyebrow: "Una experiencia a medida",
    duration: "Duración personalizada",
    meetingPoint: "A convenir",
    priceAdult: null,
    priceChild: null,
    childLabel: "Precio bajo consulta",
    capacity: null,
    minimumAdults: null,
    inventoryRule: "custom",
    description:
      "Diseñamos una visita privada adaptada a tu grupo, horario e intereses.",
    dates: [],
  },
];

export function formatPrice(value) {
  if (value === null || value === undefined) return "Consultar";
  return new Intl.NumberFormat("es-ES", {
    style: "currency",
    currency: "EUR",
  }).format(value);
}
