const { z } = require('zod');

// Um ping de GPS -- lat/lng sao obrigatorios e dentro da faixa geografica
// valida; o resto e opcional mas, se vier, precisa ser numero nao-negativo
// (heading limitado a 0-360).
const locationPing = z.object({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  speed: z.number().nonnegative().nullable().optional(),
  heading: z.number().min(0).max(360).nullable().optional(),
  accuracy: z.number().nonnegative().nullable().optional(),
  recorded_at: z.string().optional(),
});

// POST /api/trips/:id/locations aceita um ping unico OU um array (quando o
// app faz batch da fila offline) -- limitado a 200 itens por request, pra um
// cliente nao conseguir mandar um lote gigante numa unica chamada.
const locationsBody = z.union([locationPing, z.array(locationPing).max(200)]);

// POST /api/trips/:id/events -- lat/lng sao opcionais aqui (o evento pode
// vir sem GPS), mas se vierem precisam estar na faixa valida.
const tripEventBody = z.object({
  student_id: z.string().min(1),
  type: z.enum(['boarded', 'dropped']),
  lat: z.number().min(-90).max(90).nullable().optional(),
  lng: z.number().min(-180).max(180).nullable().optional(),
  received_by: z.string().trim().min(2).max(200).nullable().optional(),
});

const paymentUpdateBody = z.object({
  status: z.enum(['pending', 'paid']).optional(),
  amount: z.number().nonnegative().nullable().optional(),
  notes: z.string().max(500).nullable().optional(),
  payment_method: z.string().max(50).nullable().optional(),
  paid_at: z.string().nullable().optional(),
});

const vehicleBody = z.object({
  plate: z.string().trim().regex(/^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$/),
  model: z.string().max(100).nullable().optional(),
  capacity: z.number().int().nonnegative().nullable().optional(),
  year: z.number().int().min(1950).max(2100).nullable().optional(),
  color: z.string().max(50).nullable().optional(),
  document_expiry: z.string().nullable().optional(),
  status: z.enum(['available', 'maintenance']).optional(),
});

const studentBody = z.object({
  name: z.string().trim().min(1).max(200),
  school_name: z.string().max(200).nullable().optional(),
  home_address: z.string().max(500).nullable().optional(),
  home_postal_code: z.string().regex(/^\d{8}$/).nullable().optional(),
  home_street: z.string().max(300).nullable().optional(),
  home_number: z.string().max(30).nullable().optional(),
  home_complement: z.string().max(150).nullable().optional(),
  home_neighborhood: z.string().max(150).nullable().optional(),
  home_city: z.string().max(150).nullable().optional(),
  home_state: z.string().regex(/^[A-Z]{2}$/).nullable().optional(),
  home_lat: z.number().min(-90).max(90).nullable().optional(),
  home_lng: z.number().min(-180).max(180).nullable().optional(),
  school_id: z.string().nullable().optional(),
  monthly_fee: z.number().nonnegative().nullable().optional(),
  photo_url: z.string().url().max(1000).nullable().optional(),
  birth_date: z.string().nullable().optional(),
  class_period: z.string().max(100).nullable().optional(),
  emergency_contact_name: z.string().max(200).nullable().optional(),
  emergency_contact_phone: z.string().max(50).nullable().optional(),
  medical_notes: z.string().max(2000).nullable().optional(),
  authorized_pickup: z.string().max(1000).nullable().optional(),
  active: z.boolean().optional(),
});

const routeBody = z.object({
  name: z.string().trim().min(1).max(200),
  vehicle_id: z.string().nullable().optional(),
  driver_user_id: z.string().nullable().optional(),
  days_of_week: z.string().max(20).nullable().optional(),
  planned_time: z.string().nullable().optional(),
  planned_time_to_school: z.string().nullable().optional(),
  planned_time_to_home: z.string().nullable().optional(),
  active: z.boolean().optional(),
});

const schoolBody = z.object({
  name: z.string().trim().min(1).max(200),
  address: z.string().trim().min(1).max(600).nullable().optional(),
  phone: z.string().max(50).nullable().optional(),
  postal_code: z.string().regex(/^\d{8}$/).nullable().optional(),
  street: z.string().trim().min(1).max(300).nullable().optional(),
  number: z.string().trim().min(1).max(30).nullable().optional(),
  complement: z.string().max(150).nullable().optional(),
  neighborhood: z.string().trim().min(1).max(150).nullable().optional(),
  city: z.string().trim().min(1).max(150).nullable().optional(),
  state: z.string().regex(/^[A-Z]{2}$/).nullable().optional(),
  lat: z.number().min(-90).max(90).nullable().optional(),
  lng: z.number().min(-180).max(180).nullable().optional(),
});

const userUpdateBody = z.object({
  name: z.string().trim().min(1).max(200).optional(),
  phone: z.string().max(50).nullable().optional(),
});

const chatMessageBody = z.object({
  body: z.string().trim().min(1).max(1000),
});

// Middleware: valida req.body contra o schema, respondendo 400 com uma
// mensagem amigavel se nao bater. Em caso de sucesso, deixa req.body como
// esta (nao substitui por schema.parse) -- os handlers ja desestruturam
// campos direto de req.body, e o zod so serve de guarda aqui.
function validateBody(schema) {
  return (req, res, next) => {
    const result = schema.safeParse(req.body);
    if (!result.success) {
      const message = result.error.issues[0]?.message || 'payload invalido';
      return res.status(400).json({ error: `payload invalido: ${message}` });
    }
    next();
  };
}

module.exports = {
  locationPing,
  locationsBody,
  tripEventBody,
  paymentUpdateBody,
  vehicleBody,
  studentBody,
  routeBody,
  schoolBody,
  chatMessageBody,
  userUpdateBody,
  validateBody,
};
