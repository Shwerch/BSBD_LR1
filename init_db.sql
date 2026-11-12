-- Создание групповых ролей
CREATE ROLE app_reader NOLOGIN; -- Чтение данных приложения
CREATE ROLE app_writer NOLOGIN; -- Чтение/запись данных приложения
CREATE ROLE app_owner NOLOGIN; -- Владелец приложения (может изменять структуру)
CREATE ROLE auditor NOLOGIN; -- Роль для аудита

CREATE ROLE ddl_admin NOLOGIN; -- Может делать только DDL (создание/изменение таблиц, схем)
CREATE ROLE dml_admin NOLOGIN; -- Может делать только DML (INSERT/UPDATE/DELETE)
CREATE ROLE security_admin NOLOGIN; -- Администрирование безопасности: GRANT/REVOKE

-- Создание логин-ролей с атрибутом NOINHERIT
CREATE ROLE u_reader LOGIN NOINHERIT PASSWORD 'Qqwerty_123';
CREATE ROLE u_writer LOGIN NOINHERIT PASSWORD 'Qqwerty_123';
CREATE ROLE u_owner LOGIN NOINHERIT PASSWORD 'Qqwerty_123';
CREATE ROLE u_auditor LOGIN NOINHERIT PASSWORD 'Qqwerty_123';
CREATE ROLE u_ddl_admin LOGIN NOINHERIT PASSWORD 'Qqwerty_123';
CREATE ROLE u_dml_admin LOGIN NOINHERIT PASSWORD 'Qqwerty_123';
CREATE ROLE u_sec_admin LOGIN NOINHERIT PASSWORD 'Qqwerty_123';

-- Привязка пользователей к группам
GRANT app_reader TO u_reader;
GRANT app_writer TO u_writer;
GRANT app_owner TO u_owner;
GRANT auditor TO u_auditor;
GRANT ddl_admin TO u_ddl_admin;
GRANT dml_admin TO u_dml_admin;
GRANT security_admin TO u_sec_admin;

-- Права для администратора безопасности
ALTER ROLE security_admin CREATEROLE;
GRANT app_owner TO security_admin;


CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pgaudit;

-- Создание схем
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION app_owner;
CREATE SCHEMA IF NOT EXISTS ref AUTHORIZATION app_owner;
CREATE SCHEMA IF NOT EXISTS audit AUTHORIZATION app_owner;
CREATE SCHEMA IF NOT EXISTS stg AUTHORIZATION app_owner;


-- Схема ref
CREATE TABLE ref.confidentiality_levels (
    id SERIAL PRIMARY KEY,
    level_code VARCHAR(50) UNIQUE NOT NULL,
    description VARCHAR(255)
);

CREATE TABLE ref.diagnosis_categories (
    id SERIAL PRIMARY KEY,
    category_name VARCHAR(100) UNIQUE NOT NULL,
    icd10_version VARCHAR(50),
    retention_period_days INT CHECK (retention_period_days > 0)
);

CREATE TABLE ref.consent_types (
    id SERIAL PRIMARY KEY,
    type_name VARCHAR(100) UNIQUE NOT NULL,
    requires_verification BOOLEAN DEFAULT false
);

CREATE TABLE ref.medical_departments (
    id SERIAL PRIMARY KEY,
    department_name VARCHAR(150) UNIQUE NOT NULL,
    required_conf_level INT REFERENCES ref.confidentiality_levels(id) ON DELETE RESTRICT
);


-- Схема app
CREATE TABLE app.patients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    birth_date DATE NOT NULL,
    snils VARCHAR(14) UNIQUE NOT NULL
);

CREATE TABLE app.patient_records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES app.patients(id) ON DELETE CASCADE UNIQUE,
    oms_policy_number VARCHAR(100) UNIQUE NOT NULL,
    access_pin_hash TEXT NOT NULL,
    conf_level_id INT REFERENCES ref.confidentiality_levels(id) ON DELETE RESTRICT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    is_active BOOLEAN DEFAULT true
);

CREATE TABLE app.patient_consents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    record_id UUID NOT NULL REFERENCES app.patient_records(id) ON DELETE CASCADE,
    consent_type_id INT REFERENCES ref.consent_types(id) ON DELETE RESTRICT,
    document_number VARCHAR(50) UNIQUE NOT NULL,
    issue_date DATE NOT NULL,
    expiry_date DATE,
    is_verified BOOLEAN DEFAULT false,
    CONSTRAINT chk_consent_dates_and_status CHECK (
    (expiry_date > issue_date OR expiry_date IS NULL)
    AND (NOT is_verified OR expiry_date IS NOT NULL)
    AND (expiry_date IS NULL OR (expiry_date - issue_date) <= 7305))
);

CREATE TABLE app.diagnoses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    record_id UUID NOT NULL REFERENCES app.patient_records(id) ON DELETE CASCADE,
    diag_category_id INT REFERENCES ref.diagnosis_categories(id) ON DELETE RESTRICT,
    diagnosis_hash TEXT NOT NULL,
    clinical_notes_enc BYTEA,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE app.department_access_grants (
    record_id UUID REFERENCES app.patient_records(id) ON DELETE CASCADE,
    department_id INT REFERENCES ref.medical_departments(id) ON DELETE CASCADE,
    granted_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    expires_at TIMESTAMP WITH TIME ZONE,
    PRIMARY KEY (record_id, department_id),
    CHECK (expires_at > granted_at OR expires_at IS NULL)
);


-- Схема audit
CREATE TABLE audit.login_log (
    id SERIAL PRIMARY KEY,
    login_time TIMESTAMP WITH TIME ZONE DEFAULT now(),
    db_username VARCHAR(100) NOT NULL,
    client_ip INET
);


CREATE TABLE audit.function_calls (
    id SERIAL PRIMARY KEY,
    call_time TIMESTAMP WITH TIME ZONE DEFAULT now(),
    function_name VARCHAR(150) NOT NULL,
    caller_role VARCHAR(100) NOT NULL,
    input_params JSONB,
    success BOOLEAN NOT NULL,
    error_message TEXT
);


-- Схема stg
CREATE TABLE stg.import_buffer (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    raw_payload JSONB NOT NULL,
    import_date TIMESTAMP WITH TIME ZONE DEFAULT now(),
    source_system VARCHAR(100)
);

-- Комментарии к таблицам
COMMENT ON TABLE ref.diagnosis_categories IS 'Справочник категорий медицинских диагнозов по МКБ-10';
COMMENT ON TABLE ref.consent_types IS 'Справочник типов согласий на обработку ПДн и медицинских документов';
COMMENT ON TABLE ref.confidentiality_levels IS 'Справочник уровней конфиденциальности персональных данных';
COMMENT ON TABLE ref.medical_departments IS 'Справочник медицинских отделений, запрашивающих доступ к медкартам';
COMMENT ON TABLE app.patients IS 'Таблица персональных данных пациентов';
COMMENT ON TABLE app.patient_records IS 'Таблица электронных медицинских карт пациентов';
COMMENT ON TABLE app.patient_consents IS 'Таблица письменных согласий пациентов и удостоверяющих документов';
COMMENT ON TABLE app.diagnoses IS 'Таблица врачебной тайны и клинических диагнозов пациентов';
COMMENT ON TABLE app.department_access_grants IS 'Таблица разрешений на доступ отделений к электронным медкартам';
COMMENT ON TABLE audit.login_log IS 'Журнал авторизации пользователей в СУБД';
COMMENT ON TABLE stg.import_buffer IS 'Буфер загрузки медицинских данных из внешних систем (ЕГИСЗ, ТФОМС)';

-- Индексы для ускорения поиска по внешним ключам и частым фильтрам
CREATE INDEX idx_patient_records_conf_level ON app.patient_records(conf_level_id);
CREATE INDEX idx_patient_consents_record_id ON app.patient_consents(record_id);
CREATE INDEX idx_diagnoses_record_id ON app.diagnoses(record_id);
CREATE INDEX idx_login_log_time ON audit.login_log(login_time);




-- Генерация тестовых данных

-- 1. Заполняем справочники
INSERT INTO ref.confidentiality_levels (level_code, description) VALUES
('BASIC_REG', 'Базовый регистрационный уровень (только полис ОМС и контакты)'),
('STANDARD_OMS', 'Стандартный уровень ОМС (подтверждены СНИЛС, паспорт РФ и согласие ФЗ-152)'),
('CLINICAL', 'Клинический уровень (доступ к общей амбулаторной карте и назначениям)'),
('SPECIAL_MED', 'Особый уровень врачебной тайны (спецкатегории ПДн по ст. 10 ФЗ-152 и ст. 13 ФЗ-323)');

INSERT INTO ref.diagnosis_categories (category_name, icd10_version, retention_period_days) VALUES
('Болезни системы кровообращения (I00-I99)', 'МКБ-10 (2024)', 9125),
('Болезни органов дыхания (J00-J99)', 'МКБ-10 (2024)', 9125),
('Инфекционные и паразитарные болезни (A00-B99)', 'МКБ-10 (2024)', 18250),
('Психические расстройства и расстройства поведения (F00-F99)', 'МКБ-10 (2024)', 27375);

INSERT INTO ref.consent_types (type_name, requires_verification) VALUES
('Согласие на обработку ПДн (ст. 9 ФЗ-152)', true),
('Информированное добровольное согласие (ст. 20 ФЗ-323)', true),
('Паспорт гражданина РФ', true),
('Полис ОМС единого образца', false);

INSERT INTO ref.medical_departments (department_name, required_conf_level) VALUES
('Регистратура поликлиники', (SELECT id FROM ref.confidentiality_levels WHERE level_code = 'BASIC_REG')),
('Терапевтическое отделение', (SELECT id FROM ref.confidentiality_levels WHERE level_code = 'STANDARD_OMS')),
('Хирургический стационар', (SELECT id FROM ref.confidentiality_levels WHERE level_code = 'CLINICAL')),
('Специализированный психоневрологический диспансер', (SELECT id FROM ref.confidentiality_levels WHERE level_code = 'SPECIAL_MED'));

-- 2. Заполняем пациентов (10 строк)
INSERT INTO app.patients (first_name, last_name, birth_date, snils) VALUES
('Иван', 'Иванов', '1990-05-15', '111-222-333 44'),
('Мария', 'Смирнова', '1985-08-20', '111-222-333 45'),
('Алексей', 'Петров', '1992-11-10', '111-222-333 46'),
('Елена', 'Соколова', '1988-03-25', '111-222-333 47'),
('Дмитрий', 'Волков', '1975-12-05', '111-222-333 48'),
('Ольга', 'Морозова', '1995-07-30', '111-222-333 49'),
('Сергей', 'Новиков', '1980-01-18', '111-222-333 50'),
('Анна', 'Зайцева', '2000-09-12', '111-222-333 51'),
('Виктор', 'Кузнецов', '1968-04-22', '111-222-333 52'),
('Екатерина', 'Попова', '1998-02-14', '111-222-333 53');

-- 3. Заполняем электронные медкарты пациентов (пин-коды доступа хешируются через pgcrypto)
-- Для наглядной демонстрации RLS 6 карт создаются активными (true), а 4 архивными (false)
INSERT INTO app.patient_records (patient_id, oms_policy_number, access_pin_hash, conf_level_id, is_active)
SELECT 
    id, 
    '770000' || replace(split_part(snils, '-', 3), ' ', '') || '000001', 
    crypt('MedPin123!', gen_salt('bf', 8)), 
    (SELECT id FROM ref.confidentiality_levels WHERE level_code = 'STANDARD_OMS'),
    CASE WHEN snils IN ('111-222-333 48', '111-222-333 49', '111-222-333 52', '111-222-333 53') THEN false ELSE true END
FROM app.patients;

-- 4. Добавляем письменные согласия на обработку ПДн (связь с электронной медкартой)
INSERT INTO app.patient_consents (record_id, consent_type_id, document_number, issue_date, expiry_date, is_verified)
SELECT 
    pr.id, 
    (SELECT id FROM ref.consent_types WHERE type_name = 'Согласие на обработку ПДн (ст. 9 ФЗ-152)'), 
    'ПДН-' || cast(floor(random() * 90 + 10) as int) || '-' || cast(floor(random() * 900000 + 100000) as int),
    '2023-01-15'::date,
    '2028-01-15'::date,
    true
FROM app.patient_records pr;

-- 5. Добавляем зашифрованные клинические диагнозы для части медкарт (шифрование clinical_notes_enc)
INSERT INTO app.diagnoses (record_id, diag_category_id, diagnosis_hash, clinical_notes_enc)
SELECT 
    pr.id,
    (SELECT id FROM ref.diagnosis_categories WHERE category_name = 'Болезни системы кровообращения (I00-I99)'),
    encode(digest('icd10_I10_essential_hypertension_' || pr.oms_policy_number, 'sha256'), 'hex'),
    pgp_sym_encrypt('Диагноз по МКБ-10: I10. Эссенциальная гипертензия. Назначена плановая терапия.', 'secret_med_key_from_env')
FROM app.patient_records pr
LIMIT 5;

-- 6. Добавляем разрешения медицинским отделениям на доступ к медкартам
INSERT INTO app.department_access_grants (record_id, department_id, expires_at)
SELECT 
    pr.id,
    md.id,
    now() + interval '1 year'
FROM app.patient_records pr
CROSS JOIN ref.medical_departments md
WHERE random() > 0.7;



-- Назначение привилегий и защита данных

-- Отзыв прав у PUBLIC
REVOKE ALL ON DATABASE med_records_secure FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA app, ref, audit, stg FROM PUBLIC;

-- Базовый доступ на подключение
GRANT CONNECT ON DATABASE med_records_secure TO u_reader, u_writer, u_owner, u_auditor, u_ddl_admin, u_dml_admin, u_sec_admin;

-- Права для app_owner
GRANT ALL PRIVILEGES ON SCHEMA app, ref, audit, stg TO app_owner;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA app, ref, audit, stg TO app_owner;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA app, ref, audit, stg TO app_owner;

-- Разделение обязанностей

-- DDL Admin может создавать и менять структуру бд, но не данные
GRANT USAGE ON SCHEMA app, ref, stg, audit TO ddl_admin;
GRANT CREATE ON SCHEMA app, ref, stg, audit TO ddl_admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA app, ref, stg, audit TO ddl_admin;
REVOKE SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA app, ref, stg, audit FROM ddl_admin;

-- DML Admin может изменять данные внутри таблиц, но не меняет структуру
GRANT USAGE ON SCHEMA app, ref, stg, audit TO dml_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app, ref, stg TO dml_admin;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA app, ref, stg TO dml_admin;

-- Security Admin запрет на любой доступ к бизнес-данным, он только управляет ролями
REVOKE SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app, ref, stg, audit FROM security_admin;

-- Права для ролей приложения
GRANT USAGE ON SCHEMA app, ref TO app_reader, app_writer;

-- Чтение
GRANT SELECT ON ALL TABLES IN SCHEMA app, ref TO app_reader;
GRANT SELECT, USAGE ON ALL SEQUENCES IN SCHEMA app, ref TO app_reader;

-- Чтение и запись
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app, ref TO app_writer;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA app, ref TO app_writer;

-- Изоляция схемы audit
GRANT USAGE ON SCHEMA audit TO auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO auditor;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO auditor;

-- Запрет прямой вставки в аудит для всех, кроме владельца/триггера
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA audit FROM PUBLIC, app_reader, app_writer, dml_admin;

-- Настройка привилегий по умолчанию

-- Для будущих таблиц, созданных владельцем
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app, ref 
    GRANT SELECT ON TABLES TO app_reader;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app, ref 
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_writer;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA audit 
    GRANT SELECT ON TABLES TO auditor;

-- Для будущих последовательностей
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app, ref 
    GRANT USAGE, SELECT ON SEQUENCES TO app_reader;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app, ref 
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO app_writer;


-- Включаем RLS для таблицы электронных медкарт
ALTER TABLE app.patient_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.patient_records FORCE ROW LEVEL SECURITY;

-- Политика для владельца: видит и может изменять всё
CREATE POLICY records_owner_policy 
ON app.patient_records 
FOR ALL 
TO app_owner 
USING (true) 
WITH CHECK (true);

-- Политика для читателей и писателей: видят только активные медкарты
CREATE POLICY records_active_only_policy 
ON app.patient_records 
FOR SELECT 
TO app_reader, app_writer 
USING (is_active = true);

-- Политика для писателей: могут обновлять только активные медкарты
CREATE POLICY records_update_active_policy 
ON app.patient_records 
FOR UPDATE 
TO app_writer 
USING (is_active = true)
WITH CHECK (is_active = true);


-- Функция записи лога при подключении
CREATE OR REPLACE FUNCTION audit.log_connection()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'app, public' 
AS $$
BEGIN
    INSERT INTO audit.login_log(db_username, client_ip)
    VALUES (session_user, inet_client_addr());
END;
$$;

-- Событийный триггер, который срабатывает при инициализации сессии
CREATE EVENT TRIGGER login_trigger ON login
    EXECUTE FUNCTION audit.log_connection();

-- Выдаем право security_admin на администрирование этой функции
GRANT EXECUTE ON FUNCTION audit.log_connection() TO security_admin;





-- Создание функций

-- Функция предоставления доступа отделению к электронной медкарте пациента
CREATE OR REPLACE FUNCTION app.grant_department_access(p_record_id UUID, p_department_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, ref, audit, public
AS $$
DECLARE
    v_caller VARCHAR := session_user;
    v_record_conf INT;
    v_dept_conf INT;
    v_is_active BOOLEAN;
BEGIN
    -- Валидация входных данных
    IF p_record_id IS NULL OR p_department_id IS NULL THEN
        RAISE EXCEPTION 'Параметры p_record_id и p_department_id не могут быть NULL';
    END IF;

    -- Проверка существования и статуса электронной медкарты
    SELECT conf_level_id, is_active INTO v_record_conf, v_is_active 
    FROM app.patient_records WHERE id = p_record_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Электронная медкарта не найдена';
    END IF;
    IF NOT v_is_active THEN
        RAISE EXCEPTION 'Электронная медкарта деактивирована (в архиве)';
    END IF;

    -- Проверка существования медицинского отделения
    SELECT required_conf_level INTO v_dept_conf 
    FROM ref.medical_departments WHERE id = p_department_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Медицинское отделение не найдено';
    END IF;

    -- Проверка уровня конфиденциальности
    IF v_record_conf < v_dept_conf THEN
        RAISE EXCEPTION 'Недостаточный уровень допуска медкарты для предоставления доступа отделению';
    END IF;

    -- Выполнение операции
    INSERT INTO app.department_access_grants (record_id, department_id, expires_at)
    VALUES (p_record_id, p_department_id, now() + interval '1 year')
    ON CONFLICT (record_id, department_id) 
    DO UPDATE SET expires_at = EXCLUDED.expires_at, granted_at = now();

    -- Логирование успешного выполнения
    INSERT INTO audit.function_calls(function_name, caller_role, input_params, success)
    VALUES ('app.grant_department_access', v_caller, jsonb_build_object('record_id', p_record_id, 'department_id', p_department_id), TRUE);

    RETURN TRUE;

EXCEPTION WHEN OTHERS THEN
    -- Перехват ошибки
    INSERT INTO audit.function_calls(function_name, caller_role, input_params, success, error_message)
    VALUES ('app.grant_department_access', v_caller, jsonb_build_object('record_id', p_record_id, 'department_id', p_department_id), FALSE, SQLERRM);
    RETURN FALSE;
END;
$$;



-- Функция регистрации клинического диагноза (врачебной тайны)
CREATE OR REPLACE FUNCTION app.register_diagnosis(
    p_record_id UUID, 
    p_diag_category_id INT, 
    p_diagnosis_hash TEXT, 
    p_clinical_notes_enc BYTEA
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, ref, audit, public
AS $$
DECLARE
    v_caller VARCHAR := session_user; 
    v_is_active BOOLEAN;
    v_retention_days INT;
BEGIN
    -- Валидация входных параметров
    IF p_record_id IS NULL OR p_diag_category_id IS NULL THEN
        RAISE EXCEPTION 'ID медкарты и категории диагноза не могут быть NULL';
    END IF;
    
    IF p_diagnosis_hash IS NULL OR length(trim(p_diagnosis_hash)) = 0 THEN
        RAISE EXCEPTION 'Хэш кода диагноза не может быть пустым';
    END IF;

    -- Проверка статуса электронной медкарты
    SELECT is_active INTO v_is_active 
    FROM app.patient_records WHERE id = p_record_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Электронная медкарта не найдена';
    END IF;
    IF NOT v_is_active THEN
        RAISE EXCEPTION 'Электронная медкарта деактивирована. Регистрация диагноза запрещена.';
    END IF;

    -- Проверка категории диагноза по МКБ-10
    SELECT retention_period_days INTO v_retention_days
    FROM ref.diagnosis_categories WHERE id = p_diag_category_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Недопустимая категория диагноза по МКБ-10';
    END IF;

    -- Вставка или обновление данных
    INSERT INTO app.diagnoses (record_id, diag_category_id, diagnosis_hash, clinical_notes_enc, recorded_at)
    VALUES (p_record_id, p_diag_category_id, p_diagnosis_hash, p_clinical_notes_enc, now())
    ON CONFLICT (id) DO UPDATE 
    SET diagnosis_hash = EXCLUDED.diagnosis_hash,
        clinical_notes_enc = EXCLUDED.clinical_notes_enc,
        recorded_at = EXCLUDED.recorded_at;

    -- Логирование успешного выполнения
    INSERT INTO audit.function_calls(function_name, caller_role, input_params, success)
    VALUES (
        'app.register_diagnosis', 
        v_caller, 
        jsonb_build_object('record_id', p_record_id, 'diag_category_id', p_diag_category_id), 
        TRUE
    );

    RETURN TRUE;

EXCEPTION WHEN OTHERS THEN
    -- Перехват ошибки и логирование
    INSERT INTO audit.function_calls(function_name, caller_role, input_params, success, error_message)
    VALUES (
        'app.register_diagnosis', 
        v_caller, 
        jsonb_build_object('record_id', p_record_id, 'diag_category_id', p_diag_category_id), 
        FALSE, 
        SQLERRM
    );
    RETURN FALSE;
END;
$$;



-- Функция верификации письменного согласия пациента на обработку ПДн
CREATE OR REPLACE FUNCTION app.verify_patient_consent(
    p_document_number VARCHAR(50)
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, ref, audit, public
AS $$
DECLARE
    v_caller VARCHAR := session_user;
    v_doc_id UUID;
    v_is_verified BOOLEAN;
    v_expiry_date DATE;
    v_requires_verification BOOLEAN;
BEGIN
    -- Валидация входа
    IF p_document_number IS NULL OR length(trim(p_document_number)) = 0 THEN
        RAISE EXCEPTION 'Номер документа согласия не может быть пустым';
    END IF;

    -- Получение данных согласия и его типа
    SELECT c.id, c.is_verified, c.expiry_date, ct.requires_verification 
    INTO v_doc_id, v_is_verified, v_expiry_date, v_requires_verification
    FROM app.patient_consents c
    JOIN ref.consent_types ct ON c.consent_type_id = ct.id
    WHERE c.document_number = p_document_number;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Документ согласия с номером % не найден', p_document_number;
    END IF;

    -- Проверка документа согласия
    IF NOT v_requires_verification THEN
        RAISE EXCEPTION 'Этот тип документа не требует верификации';
    END IF;

    IF v_is_verified THEN
        RAISE EXCEPTION 'Документ согласия уже верифицирован';
    END IF;

    IF v_expiry_date IS NOT NULL AND v_expiry_date < current_date THEN
        RAISE EXCEPTION 'Срок действия согласия истек. Верификация невозможна.';
    END IF;

    -- Выполнение обновления
    UPDATE app.patient_consents 
    SET is_verified = true 
    WHERE id = v_doc_id;

    -- Логирование успеха
    INSERT INTO audit.function_calls(function_name, caller_role, input_params, success)
    VALUES (
        'app.verify_patient_consent', 
        v_caller, 
        jsonb_build_object('document_number', p_document_number), 
        TRUE
    );

    RETURN TRUE;

EXCEPTION WHEN OTHERS THEN
    -- Логирование ошибки
    INSERT INTO audit.function_calls(function_name, caller_role, input_params, success, error_message)
    VALUES (
        'app.verify_patient_consent', 
        v_caller, 
        jsonb_build_object('document_number', p_document_number), 
        FALSE, 
        SQLERRM
    );
    RETURN FALSE;
END;
$$;


REVOKE ALL ON FUNCTION app.grant_department_access(UUID, INT) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.verify_patient_consent(VARCHAR) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.register_diagnosis(UUID, INT, TEXT, BYTEA) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app.grant_department_access(UUID, INT) TO app_writer;
GRANT EXECUTE ON FUNCTION app.verify_patient_consent(VARCHAR) TO app_writer;
GRANT EXECUTE ON FUNCTION app.register_diagnosis(UUID, INT, TEXT, BYTEA) TO app_writer;