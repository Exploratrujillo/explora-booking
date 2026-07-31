export const experiences = [
  {
    id: "esencial",
    name: "Trujillo Esencial",
    subtitle: "La visita imprescindible para descubrir Trujillo",
    duration: "2 horas",
    meetingPoint: "Plaza Mayor",
    priceLabel: "9,50 €",
    adultPrice: 9.5,
    childPrice: 0,
    childLabel: "Niños hasta 12 años gratis",
    capacity: 25,
    minimumAdults: 4,
    badge: "Más popular",
    imageClass: "experience-image--esencial",
    description:
      "Un recorrido por la Plaza Mayor, el conjunto histórico y los rincones esenciales de Trujillo.",
  },
  {
    id: "candil",
    name: "A la luz del Candil",
    subtitle: "Historias y leyendas cuando cae la noche",
    duration: "1 h 30 min",
    meetingPoint: "Plaza Mayor",
    priceLabel: "10 €",
    adultPrice: 10,
    childPrice: null,
    childLabel: "Actividad para mayores de 12 años",
    capacity: 25,
    minimumAdults: 4,
    badge: "Experiencia nocturna",
    imageClass: "experience-image--candil",
    description:
      "Una experiencia nocturna por el casco histórico, entre leyendas, personajes y episodios sorprendentes.",
  },
  {
    id: "exploradores",
    name: "Pequeños Exploradores",
    subtitle: "Trujillo en familia, jugando y aprendiendo",
    duration: "2 horas",
    meetingPoint: "Plaza Mayor",
    priceLabel: "Desde 6 €",
    adultPrice: 10,
    childPrice: 6,
    childLabel: "Niños de 4 a 14 años: 6 € · 0 a 3 años gratis",
    capacity: 25,
    minimumAdults: 4,
    badge: "Ideal para familias",
    imageClass: "experience-image--exploradores",
    description:
      "Una visita participativa para familias, con pruebas, historias y actividades adaptadas a los más pequeños.",
  },
  {
    id: "privada",
    name: "Visita privada",
    subtitle: "Una experiencia exclusiva y personalizada",
    duration: "A medida",
    meetingPoint: "A convenir",
    priceLabel: "Consultar",
    adultPrice: null,
    childPrice: null,
    childLabel: "Precio según grupo y servicio",
    capacity: null,
    minimumAdults: null,
    badge: "Exclusiva",
    imageClass: "experience-image--privada",
    description:
      "Una visita diseñada para grupos, familias, empresas o viajeros que buscan un servicio totalmente personalizado.",
  },
];

export const availableDates = {
  esencial: ["2026-08-01", "2026-08-02", "2026-08-05", "2026-08-08", "2026-08-09"],
  candil: ["2026-08-01", "2026-08-07", "2026-08-08", "2026-08-14"],
  exploradores: ["2026-08-02", "2026-08-09", "2026-08-16"],
  privada: ["2026-08-04", "2026-08-06", "2026-08-11", "2026-08-13"],
};

export const schedules = {
  esencial: ["10:30", "17:30"],
  candil: ["21:30"],
  exploradores: ["11:00"],
  privada: ["10:00", "12:00", "17:00", "19:00"],
};
