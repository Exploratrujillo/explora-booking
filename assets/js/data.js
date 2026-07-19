const PRODUCTS = [
  {
    id: "esencial",
    order: 1,
    active: true,

    name: "Trujillo Esencial",
    badge: "Más reservada",

    description:
      "La visita imprescindible para descubrir Trujillo por primera vez.",

    image: "assets/images/products/trujillo-esencial.jpg",

    duration: "2 horas",

    meetingPoint: "Plaza Mayor",

    prices: {
      adult: 9.50,
      child: 0
    },

    ages: {
      childFreeUntil: 12
    },

    inventory: {
      capacity: 25,
      childrenCount: false
    },

    booking: {
      payment: "Presencial",
      minimumAdults: 4
    }
  },

  {
    id: "candil",
    order: 2,
    active: true,

    name: "A la luz del Candil",

    badge: "Experiencia nocturna",

    description:
      "Descubre el lado más misterioso de Trujillo iluminado por la luz del candil.",

    image: "assets/images/products/candil.jpg",

    duration: "2 horas",

    meetingPoint: "Plaza Mayor",

    prices: {
      adult: 10.00
    },

    ages: {
      minimum: 12
    },

    inventory: {
      capacity: 25,
      childrenCount: true
    },

    booking: {
      payment: "Presencial",
      minimumAdults: 4
    }
  },

  {
    id: "exploradores",
    order: 3,
    active: true,

    name: "Pequeños Exploradores",

    badge: "Ideal para familias",

    description:
      "Una aventura pensada para aprender jugando mientras descubrimos Trujillo.",

    image: "assets/images/products/exploradores.jpg",

    duration: "2 horas",

    meetingPoint: "Plaza Mayor",

    prices: {
      adult: 10.00,
      child: 6.00
    },

    ages: {
      childFrom: 4,
      childTo: 14,
      freeUntil: 3
    },

    inventory: {
      capacity: 25,
      childrenCount: true
    },

    booking: {
      payment: "Presencial",
      minimumAdults: 4
    }
  },

  {
    id: "privada",
    order: 4,
    active: true,

    name: "Visita Privada",

    badge: "Exclusiva",

    description:
      "Una visita diseñada únicamente para vuestro grupo.",

    image: "assets/images/products/privada.jpg",

    duration: "A medida",

    meetingPoint: "A convenir",

    prices: {
      from: true
    },

    inventory: {
      private: true
    },

    booking: {
      payment: "Presencial"
    }
  }
];