-- =====================================================================
--  نظام العناية لخدمات السيارات — قاعدة البيانات (Neon / PostgreSQL)
--  كل عميل (ورشة) له مشروع Neon مستقل، فالسكربت مصمم لمنشأة واحدة.
--  يُشغّل مرة واحدة على قاعدة جديدة بدور المالك (neondb_owner).
-- =====================================================================

BEGIN;

-- يجب تفعيل Data API و Neon Auth من لوحة Neon قبل التشغيل (ينشئ دوري authenticated / anonymous)
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated')
       OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anonymous') THEN
        RAISE EXCEPTION 'فعّل Data API من لوحة Neon أولاً ثم أعد تشغيل السكربت';
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- 1) إعدادات المنشأة (صف واحد فقط) + عداد الفواتير المتسلسل
-- ---------------------------------------------------------------------
CREATE TABLE settings (
    id                 smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    store_name         text        NOT NULL,
    cr_number          text        NOT NULL,
    vat_number         text        NOT NULL CHECK (vat_number ~ '^3[0-9]{13}3$'),
    address            text,
    phone              text,
    vat_rate           numeric(5,4) NOT NULL DEFAULT 0.15,
    invoice_prefix     text        NOT NULL DEFAULT 'INV',
    last_invoice_no    bigint      NOT NULL DEFAULT 0,   -- يُحدَّث داخل نفس معاملة الإصدار → ترقيم بلا فجوات
    updated_at         timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 2) المستخدمون والصلاحيات (مرتبطون بحسابات Neon Auth)
-- ---------------------------------------------------------------------
CREATE TABLE app_users (
    user_id     text PRIMARY KEY,                 -- معرّف المستخدم من Neon Auth (auth.user_id())
    full_name   text NOT NULL,
    role        text NOT NULL CHECK (role IN ('admin','cashier')),
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION current_app_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT role FROM app_users WHERE user_id = auth.user_id() AND is_active;
$$;

CREATE OR REPLACE FUNCTION is_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT coalesce(current_app_role() = 'admin', false); $$;

CREATE OR REPLACE FUNCTION is_staff() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT current_app_role() IS NOT NULL; $$;

-- ---------------------------------------------------------------------
-- 3) الفنيون، الأقسام، الأصناف
-- ---------------------------------------------------------------------
CREATE TABLE technicians (
    id          serial PRIMARY KEY,
    name        text NOT NULL,
    specialty   text,
    is_active   boolean NOT NULL DEFAULT true
);

CREATE TABLE categories (
    id          text PRIMARY KEY,                 -- tires / oils / batteries / services
    name_ar     text NOT NULL,
    is_service  boolean NOT NULL DEFAULT false,   -- الخدمات لا تُخصم من المخزون
    sort_order  int NOT NULL DEFAULT 0
);

CREATE TABLE products (
    id              serial PRIMARY KEY,
    code            text UNIQUE NOT NULL,
    barcode         text UNIQUE,
    name_ar         text NOT NULL,
    category_id     text NOT NULL REFERENCES categories(id),
    price           numeric(10,2) NOT NULL CHECK (price >= 0),   -- شامل الضريبة
    cost            numeric(10,2) NOT NULL DEFAULT 0 CHECK (cost >= 0),
    stock           int NOT NULL DEFAULT 0 CHECK (stock >= 0),
    min_stock       int NOT NULL DEFAULT 5,
    commission      numeric(10,2) NOT NULL DEFAULT 0,            -- عمولة الفني لكل وحدة (ر.س)
    is_active       boolean NOT NULL DEFAULT true,
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 4) الورديات
-- ---------------------------------------------------------------------
CREATE TABLE shifts (
    id                serial PRIMARY KEY,
    opened_by         text NOT NULL REFERENCES app_users(user_id),
    opened_at         timestamptz NOT NULL DEFAULT now(),
    opening_cash      numeric(10,2) NOT NULL DEFAULT 0,
    closed_by         text REFERENCES app_users(user_id),
    closed_at         timestamptz,
    counted_cash      numeric(10,2),
    counted_card      numeric(10,2),
    counted_transfer  numeric(10,2),
    notes             text
);
-- وردية مفتوحة واحدة فقط في أي وقت
CREATE UNIQUE INDEX one_open_shift ON shifts ((true)) WHERE closed_at IS NULL;

-- ---------------------------------------------------------------------
-- 5) أوامر العمل بالورشة
-- ---------------------------------------------------------------------
CREATE TABLE workshop_jobs (
    id                 serial PRIMARY KEY,
    plate_number       text NOT NULL,
    vehicle_model      text,
    odometer           int,
    customer_phone     text,
    requested_service  text,
    technician_id      int REFERENCES technicians(id),
    status             text NOT NULL DEFAULT 'waiting'
                       CHECK (status IN ('waiting','in_progress','completed','invoiced','cancelled')),
    created_by         text REFERENCES app_users(user_id),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 6) الفواتير وبنودها
-- ---------------------------------------------------------------------
CREATE TABLE invoices (
    id                 bigserial PRIMARY KEY,
    invoice_no         bigint UNIQUE NOT NULL,          -- رقم متسلسل بلا فجوات
    invoice_number     text   UNIQUE NOT NULL,          -- النص المطبوع مثل INV-000123
    shift_id           int NOT NULL REFERENCES shifts(id),
    job_id             int REFERENCES workshop_jobs(id),
    cashier_id         text NOT NULL REFERENCES app_users(user_id),
    plate_number       text,
    vehicle_model      text,
    odometer           int,
    customer_phone     text,
    gross_total        numeric(10,2) NOT NULL,          -- قبل الخصم، شامل الضريبة
    discount_type      text NOT NULL DEFAULT 'amount' CHECK (discount_type IN ('amount','percent')),
    discount_value     numeric(10,2) NOT NULL DEFAULT 0,
    discount_amount    numeric(10,2) NOT NULL DEFAULT 0,
    subtotal_excl_vat  numeric(10,2) NOT NULL,
    vat_amount         numeric(10,2) NOT NULL,
    total_incl_vat     numeric(10,2) NOT NULL,
    paid_cash          numeric(10,2) NOT NULL DEFAULT 0,
    paid_card          numeric(10,2) NOT NULL DEFAULT 0,
    paid_transfer      numeric(10,2) NOT NULL DEFAULT 0,
    qr_base64          text NOT NULL,
    status             text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued','void')),
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (paid_cash + paid_card + paid_transfer = total_incl_vat)
);

CREATE TABLE invoice_items (
    id              bigserial PRIMARY KEY,
    invoice_id      bigint NOT NULL REFERENCES invoices(id) ON DELETE RESTRICT,
    product_id      int NOT NULL REFERENCES products(id),
    name_ar         text NOT NULL,                -- نسخة ثابتة من اسم الصنف وقت البيع
    unit_price      numeric(10,2) NOT NULL,
    unit_cost       numeric(10,2) NOT NULL,
    qty             int NOT NULL CHECK (qty > 0),
    line_total      numeric(10,2) NOT NULL,
    technician_id   int REFERENCES technicians(id),   -- العمولة على مستوى البند
    commission      numeric(10,2) NOT NULL DEFAULT 0
);
CREATE INDEX ON invoice_items (invoice_id);
CREATE INDEX ON invoice_items (technician_id);
CREATE INDEX ON invoices (shift_id);
CREATE INDEX ON invoices (created_at);

-- ---------------------------------------------------------------------
-- 7) المصروفات (للتقارير والأرباح)
-- ---------------------------------------------------------------------
CREATE TABLE expenses (
    id          serial PRIMARY KEY,
    shift_id    int REFERENCES shifts(id),
    description text NOT NULL,
    amount      numeric(10,2) NOT NULL CHECK (amount > 0),
    paid_from   text NOT NULL DEFAULT 'cash' CHECK (paid_from IN ('cash','card','transfer')),
    created_by  text REFERENCES app_users(user_id),
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ترميز QR هيئة الزكاة (TLV → Base64) — المرحلة الأولى
CREATE OR REPLACE FUNCTION tlv(p_tag int, p_value text) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$
    SELECT set_byte('\x00'::bytea, 0, p_tag)
        || set_byte('\x00'::bytea, 0, octet_length(convert_to(p_value,'UTF8')))
        || convert_to(p_value, 'UTF8');
$$;

CREATE OR REPLACE FUNCTION zatca_qr(p_seller text, p_vat text, p_ts text, p_total numeric, p_vat_amt numeric)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(encode(
        tlv(1, p_seller) || tlv(2, p_vat) || tlv(3, p_ts) ||
        tlv(4, to_char(p_total, 'FM999999990.00')) || tlv(5, to_char(p_vat_amt, 'FM999999990.00')),
        'base64'), E'\n', '');
$$;

-- =====================================================================
-- 8) دالة إصدار الفاتورة (معاملة واحدة ذرية)
--    الواجهة ترسل الأصناف والكميات فقط؛ الأسعار والضريبة تُحسب هنا
--    حتى لا يستطيع أحد التلاعب بالمبالغ من المتصفح.
--    p_payload مثال:
--    {"job_id":3,"plate":"أ ب ج 1234","model":"كامري","odometer":1200,"phone":"05..",
--     "discount_type":"amount","discount_value":10,
--     "paid_cash":100,"paid_card":0,"paid_transfer":0,
--     "items":[{"product_id":101,"qty":2,"technician_id":1}],
--     "qr_timestamp":"2026-10-27T13:45:00Z"}
-- =====================================================================
CREATE OR REPLACE FUNCTION issue_invoice(p_payload jsonb)
RETURNS invoices
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_user      text := auth.user_id();
    v_settings  settings;
    v_shift     int;
    v_no        bigint;
    v_inv       invoices;
    v_item      jsonb;
    v_prod      products;
    v_is_srv    boolean;
    v_gross     numeric(12,2) := 0;
    v_disc      numeric(12,2);
    v_total     numeric(12,2);
    v_sub       numeric(12,2);
    v_vat       numeric(12,2);
    v_paid      numeric(12,2);
    v_ts        text;
BEGIN
    IF NOT is_staff() THEN RAISE EXCEPTION 'غير مصرح'; END IF;
    IF jsonb_array_length(coalesce(p_payload->'items','[]')) = 0 THEN
        RAISE EXCEPTION 'الفاتورة فارغة';
    END IF;

    SELECT id INTO v_shift FROM shifts WHERE closed_at IS NULL;
    IF v_shift IS NULL THEN RAISE EXCEPTION 'لا توجد وردية مفتوحة'; END IF;

    -- قفل صف الإعدادات للحصول على الرقم التالي بلا فجوات
    SELECT * INTO v_settings FROM settings WHERE id = 1 FOR UPDATE;
    v_no := v_settings.last_invoice_no + 1;

    -- حساب الإجمالي من أسعار القاعدة + التحقق من المخزون
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_payload->'items') LOOP
        SELECT * INTO v_prod FROM products
         WHERE id = (v_item->>'product_id')::int AND is_active FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'صنف غير موجود: %', v_item->>'product_id'; END IF;
        SELECT is_service INTO v_is_srv FROM categories WHERE id = v_prod.category_id;
        IF NOT v_is_srv AND v_prod.stock < (v_item->>'qty')::int THEN
            RAISE EXCEPTION 'المخزون لا يكفي: %', v_prod.name_ar;
        END IF;
        v_gross := v_gross + v_prod.price * (v_item->>'qty')::int;
    END LOOP;

    IF p_payload->>'discount_type' = 'percent' THEN
        v_disc := round(v_gross * least(greatest(coalesce((p_payload->>'discount_value')::numeric,0),0),100) / 100, 2);
    ELSE
        v_disc := least(greatest(coalesce((p_payload->>'discount_value')::numeric,0),0), v_gross);
    END IF;

    v_total := round(v_gross - v_disc, 2);
    v_sub   := round(v_total / (1 + v_settings.vat_rate), 2);
    v_vat   := v_total - v_sub;

    v_paid := coalesce((p_payload->>'paid_cash')::numeric,0)
            + coalesce((p_payload->>'paid_card')::numeric,0)
            + coalesce((p_payload->>'paid_transfer')::numeric,0);
    IF v_paid <> v_total THEN
        RAISE EXCEPTION 'مجموع الدفعات (%) لا يساوي الإجمالي (%)', v_paid, v_total;
    END IF;

    v_ts := coalesce(p_payload->>'qr_timestamp', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));

    INSERT INTO invoices (invoice_no, invoice_number, shift_id, job_id, cashier_id,
        plate_number, vehicle_model, odometer, customer_phone,
        gross_total, discount_type, discount_value, discount_amount,
        subtotal_excl_vat, vat_amount, total_incl_vat,
        paid_cash, paid_card, paid_transfer, qr_base64)
    VALUES (v_no, v_settings.invoice_prefix || '-' || lpad(v_no::text, 6, '0'), v_shift,
        (p_payload->>'job_id')::int, v_user,
        p_payload->>'plate', p_payload->>'model', (p_payload->>'odometer')::int, p_payload->>'phone',
        v_gross, coalesce(p_payload->>'discount_type','amount'),
        coalesce((p_payload->>'discount_value')::numeric,0), v_disc,
        v_sub, v_vat, v_total,
        coalesce((p_payload->>'paid_cash')::numeric,0),
        coalesce((p_payload->>'paid_card')::numeric,0),
        coalesce((p_payload->>'paid_transfer')::numeric,0),
        zatca_qr(v_settings.store_name, v_settings.vat_number, v_ts, v_total, v_vat))
    RETURNING * INTO v_inv;

    -- البنود + خصم المخزون + العمولات
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_payload->'items') LOOP
        SELECT * INTO v_prod FROM products WHERE id = (v_item->>'product_id')::int;
        INSERT INTO invoice_items (invoice_id, product_id, name_ar, unit_price, unit_cost, qty,
                                   line_total, technician_id, commission)
        VALUES (v_inv.id, v_prod.id, v_prod.name_ar, v_prod.price, v_prod.cost,
                (v_item->>'qty')::int, v_prod.price * (v_item->>'qty')::int,
                (v_item->>'technician_id')::int,
                CASE WHEN v_item->>'technician_id' IS NULL THEN 0
                     ELSE v_prod.commission * (v_item->>'qty')::int END);

        UPDATE products p SET stock = stock - (v_item->>'qty')::int, updated_at = now()
          FROM categories c
         WHERE p.id = v_prod.id AND c.id = p.category_id AND NOT c.is_service;
    END LOOP;

    UPDATE settings SET last_invoice_no = v_no, updated_at = now() WHERE id = 1;

    IF p_payload->>'job_id' IS NOT NULL THEN
        UPDATE workshop_jobs SET status = 'invoiced', updated_at = now()
         WHERE id = (p_payload->>'job_id')::int;
    END IF;

    RETURN v_inv;
END $$;


-- إغلاق الوردية مع حفظ عدّ الدرج
CREATE OR REPLACE FUNCTION close_shift(p_cash numeric, p_card numeric, p_transfer numeric, p_notes text DEFAULT NULL)
RETURNS shifts LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v shifts;
BEGIN
    IF NOT is_staff() THEN RAISE EXCEPTION 'غير مصرح'; END IF;
    UPDATE shifts SET closed_at = now(), closed_by = auth.user_id(),
           counted_cash = p_cash, counted_card = p_card, counted_transfer = p_transfer, notes = p_notes
     WHERE closed_at IS NULL RETURNING * INTO v;
    IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد وردية مفتوحة'; END IF;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION open_shift(p_opening_cash numeric DEFAULT 0)
RETURNS shifts LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v shifts;
BEGIN
    IF NOT is_staff() THEN RAISE EXCEPTION 'غير مصرح'; END IF;
    INSERT INTO shifts (opened_by, opening_cash) VALUES (auth.user_id(), p_opening_cash) RETURNING * INTO v;
    RETURN v;
END $$;

-- ملخص الوردية (Z-Report)
CREATE OR REPLACE VIEW shift_summary WITH (security_invoker = true) AS
SELECT s.id AS shift_id, s.opened_at, s.closed_at, s.opening_cash,
       count(i.id)                                   AS invoices_count,
       coalesce(sum(i.total_incl_vat),0)             AS total_sales,
       coalesce(sum(i.vat_amount),0)                 AS total_vat,
       coalesce(sum(i.paid_cash),0)                  AS expected_cash_sales,
       coalesce(sum(i.paid_card),0)                  AS expected_card,
       coalesce(sum(i.paid_transfer),0)              AS expected_transfer,
       s.counted_cash, s.counted_card, s.counted_transfer
  FROM shifts s
  LEFT JOIN invoices i ON i.shift_id = s.id AND i.status = 'issued'
 GROUP BY s.id;

-- =====================================================================
-- 9) الأمان: الصلاحيات + RLS
--    anonymous: لا شيء إطلاقاً.  authenticated: حسب الدور في app_users.
-- =====================================================================
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anonymous;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anonymous, PUBLIC;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT INSERT, UPDATE ON workshop_jobs, products, technicians, categories, expenses, settings, app_users TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON FUNCTION issue_invoice(jsonb), open_shift(numeric), close_shift(numeric,numeric,numeric,text),
                          is_admin(), is_staff(), current_app_role() TO authenticated;
-- الفواتير لا تُكتب مباشرة؛ فقط عبر issue_invoice
REVOKE INSERT, UPDATE, DELETE ON invoices, invoice_items, shifts FROM authenticated;

ALTER TABLE settings       ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_users      ENABLE ROW LEVEL SECURITY;
ALTER TABLE technicians    ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories     ENABLE ROW LEVEL SECURITY;
ALTER TABLE products       ENABLE ROW LEVEL SECURITY;
ALTER TABLE shifts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE workshop_jobs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices       ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoice_items  ENABLE ROW LEVEL SECURITY;
ALTER TABLE expenses       ENABLE ROW LEVEL SECURITY;

-- القراءة: أي موظف فعّال
CREATE POLICY staff_read ON settings      FOR SELECT TO authenticated USING (is_staff());
CREATE POLICY staff_read ON technicians   FOR SELECT TO authenticated USING (is_staff());
CREATE POLICY staff_read ON categories    FOR SELECT TO authenticated USING (is_staff());
CREATE POLICY staff_read ON products      FOR SELECT TO authenticated USING (is_staff());
CREATE POLICY staff_read ON shifts        FOR SELECT TO authenticated USING (is_staff());
CREATE POLICY staff_read ON workshop_jobs FOR SELECT TO authenticated USING (is_staff());
CREATE POLICY staff_read ON invoices      FOR SELECT TO authenticated USING (is_staff());
CREATE POLICY staff_read ON invoice_items FOR SELECT TO authenticated USING (is_staff());
CREATE POLICY staff_read ON expenses      FOR SELECT TO authenticated USING (is_staff());
CREATE POLICY self_or_admin_read ON app_users FOR SELECT TO authenticated
    USING (user_id = auth.user_id() OR is_admin());

-- الكاشير: يسجّل ويحدّث أوامر الورشة، ويسجّل المصروفات
CREATE POLICY staff_write ON workshop_jobs FOR INSERT TO authenticated WITH CHECK (is_staff());
CREATE POLICY staff_update ON workshop_jobs FOR UPDATE TO authenticated USING (is_staff()) WITH CHECK (is_staff());
CREATE POLICY staff_write ON expenses FOR INSERT TO authenticated WITH CHECK (is_staff());

-- المدير فقط: الأصناف والأسعار، الفنيون، الأقسام، الإعدادات، المستخدمون
CREATE POLICY admin_write ON products    FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY admin_write ON technicians FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY admin_write ON categories  FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY admin_write ON settings    FOR UPDATE TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY admin_write ON app_users   FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());

-- منع تعديل عداد الفواتير يدوياً حتى من المدير (يتغير فقط داخل issue_invoice)
REVOKE UPDATE ON settings FROM authenticated;
GRANT UPDATE (store_name, cr_number, vat_number, address, phone, invoice_prefix, updated_at)
    ON settings TO authenticated;

-- إدارة الموظفين (المدير)
-- قائمة حسابات الدخول (للمدير فقط) لتفعيل الموظفين
CREATE OR REPLACE FUNCTION list_auth_users()
RETURNS TABLE (user_id text, email text, name text, created_at timestamptz, role text, is_active boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT is_admin() THEN RAISE EXCEPTION 'غير مصرح'; END IF;
    RETURN QUERY
    SELECT u.id::text, u.email::text, u.name::text, u."createdAt"::timestamptz, a.role, a.is_active
      FROM neon_auth."user" u
      LEFT JOIN app_users a ON a.user_id = u.id::text
     ORDER BY (a.user_id IS NULL) DESC, u."createdAt" DESC;
END $$;

-- تفعيل/تعديل موظف (المدير فقط) — لا يسمح للمدير بإيقاف نفسه
CREATE OR REPLACE FUNCTION set_staff(p_user_id text, p_full_name text, p_role text, p_active boolean)
RETURNS app_users LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v app_users;
BEGIN
    IF NOT is_admin() THEN RAISE EXCEPTION 'غير مصرح'; END IF;
    IF p_role NOT IN ('admin','cashier') THEN RAISE EXCEPTION 'دور غير صالح'; END IF;
    IF p_user_id = auth.user_id() AND (NOT p_active OR p_role <> 'admin') THEN
        RAISE EXCEPTION 'لا يمكنك إيقاف حسابك أو إزالة صلاحية المدير عن نفسك';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM neon_auth."user" WHERE id::text = p_user_id) THEN
        RAISE EXCEPTION 'الحساب غير موجود';
    END IF;
    INSERT INTO app_users (user_id, full_name, role, is_active)
    VALUES (p_user_id, p_full_name, p_role, p_active)
    ON CONFLICT (user_id) DO UPDATE
       SET full_name = EXCLUDED.full_name, role = EXCLUDED.role, is_active = EXCLUDED.is_active
    RETURNING * INTO v;
    RETURN v;
END $$;

REVOKE ALL ON FUNCTION list_auth_users(), set_staff(text,text,text,boolean) FROM PUBLIC, anonymous;
GRANT EXECUTE ON FUNCTION list_auth_users(), set_staff(text,text,text,boolean) TO authenticated;

-- قراءة إعدادات المنشأة للموظفين
CREATE OR REPLACE FUNCTION get_store_settings() RETURNS settings
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v settings;
BEGIN
    IF NOT is_staff() THEN RAISE EXCEPTION 'غير مصرح'; END IF;
    SELECT * INTO v FROM settings WHERE id = 1;
    RETURN v;
END $$;
REVOKE ALL ON FUNCTION get_store_settings() FROM PUBLIC, anonymous;
GRANT EXECUTE ON FUNCTION get_store_settings() TO authenticated;

-- إلغاء الصلاحيات الافتراضية الزائدة التي يمنحها Neon عند تفعيل Data API
REVOKE INSERT, DELETE, TRUNCATE ON settings, app_users, technicians, categories, workshop_jobs, expenses FROM authenticated;
REVOKE DELETE, TRUNCATE ON products FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON invoices, invoice_items, shifts, shift_summary FROM authenticated;
GRANT INSERT ON technicians, categories, workshop_jobs, expenses, app_users TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE INSERT, UPDATE, DELETE ON TABLES FROM authenticated;

-- =====================================================================
-- 10) بيانات أولية (عدّلها ببيانات المنشأة الحقيقية)
-- =====================================================================
INSERT INTO settings (store_name, cr_number, vat_number, address)
VALUES ('العناية لخدمات السيارات', '1010887766', '310998877600003', 'الرياض - طريق الملك فهد');

INSERT INTO categories (id, name_ar, is_service, sort_order) VALUES
  ('tires',     'الإطارات',            false, 1),
  ('oils',      'الزيوت والفلاتر',      false, 2),
  ('batteries', 'البطاريات',            false, 3),
  ('services',  'خدمات الصيانة والوزن', true,  4);

INSERT INTO technicians (name, specialty) VALUES
  ('محمد علي',    'فني إطارات وميزان'),
  ('سوهان كومار', 'فني زيوت وصيانة'),
  ('حسان محمود',  'ميكانيكي عام');

COMMIT;

-- بعد إنشاء أول حساب في Neon Auth، اجعله مديراً:
-- INSERT INTO app_users (user_id, full_name, role) VALUES ('<user-id-from-neon-auth>', 'اسم المدير', 'admin');
