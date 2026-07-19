// ==============================
// Explora Booking
// Generador de experiencias
// ==============================

const container = document.querySelector("#products");

function formatPrice(product) {

    if (product.id === "privada") {
        return "Consultar";
    }

    return product.prices.adult.toFixed(2).replace(".", ",") + " €";
}

function createCard(product) {

    return `
    <article class="product-card" data-id="${product.id}">

        <div class="product-image">

            <img src="${product.image}" alt="${product.name}">

            <span class="badge">
                ${product.badge}
            </span>

        </div>

        <div class="product-content">

            <h2>${product.name}</h2>

            <p class="description">
                ${product.description}
            </p>

            <div class="product-info">

                <span>⏱ ${product.duration}</span>

                <span>📍 ${product.meetingPoint}</span>

            </div>

            <div class="product-footer">

                <div class="price">

                    Desde

                    <strong>${formatPrice(product)}</strong>

                </div>

                <button class="select-button">

                    Elegir experiencia

                </button>

            </div>

        </div>

    </article>
    `;
}

function renderProducts() {

    container.innerHTML = "";

    PRODUCTS
        .sort((a, b) => a.order - b.order)
        .forEach(product => {

            container.innerHTML += createCard(product);

        });

}

renderProducts();
