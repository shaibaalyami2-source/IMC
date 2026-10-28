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
