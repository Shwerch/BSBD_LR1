-- КЕЙС 1 [Позитивный]: Чтение разрешённых таблиц ролью чтения (app_reader)
SET ROLE app_reader;
SELECT id, first_name, snils 
FROM app.patients 
LIMIT 2;
-- Ожидание: Успешная выборка данных пациентов.


-- КЕЙС 2 [Негативный]: Попытка выполнения DDL неадмином (app_writer)
SET ROLE app_writer;
CREATE TABLE app.secret_med_data (id INT);
-- Ожидание: Ошибка "permission denied for schema app". Создавать таблицы может только ddl_admin или владелец.


-- КЕЙС 3 [Позитивный]: Выполнение разрешенного DML ролью (app_writer)
SET ROLE app_writer;
UPDATE app.patients 
SET first_name = 'Иван (обновлен)' 
WHERE snils = '111-222-333 44';
-- Ожидание: Успешное выполнение (UPDATE 1).


-- КЕЙС 4 [Негативный]: Прямая попытка DML в схему audit (app_writer)
SET ROLE app_writer;
DELETE FROM audit.login_log;
-- Ожидание: Ошибка "permission denied for table login_log". Никто кроме владельца/функций не может писать в аудит.


-- КЕЙС 5 [Негативный]: Вызов SECURITY DEFINER функции без прав (app_reader)
SET ROLE app_reader;
SELECT app.verify_patient_consent('ПДН-12-345678');
-- Ожидание: Ошибка "permission denied for function verify_patient_consent". Права на выполнение (EXECUTE) выданы только app_writer.


-- КЕЙС 6 [Негативный]: SECURITY DEFINER с невалидными данными (app_writer)
SET ROLE app_writer;
-- Пытаемся верифицировать несуществующий номер согласия на обработку ПДн
SELECT app.verify_patient_consent('FAKE-CONSENT-999');
-- Ожидание: Функция отработает и вернет FALSE, перехватив кастомную ошибку "Документ согласия с номером FAKE-CONSENT-999 не найден".


-- КЕЙС 7 [Позитивный]: SECURITY DEFINER с валидными данными (app_writer)
SET ROLE app_writer;
INSERT INTO app.patient_consents (record_id, consent_type_id, document_number, issue_date, expiry_date, is_verified)
VALUES (
    (SELECT id FROM app.patient_records WHERE is_active = true LIMIT 1),
    (SELECT id FROM ref.consent_types WHERE type_name = 'Согласие на обработку ПДн (ст. 9 ФЗ-152)' LIMIT 1),
    'TEST-CONSENT-777',
    '2024-01-01',
    '2029-01-01',
    false
);

-- Вызов функции для успешной верификации созданного документа согласия
SELECT app.verify_patient_consent('TEST-CONSENT-777');
-- Ожидание: Функция вернет TRUE. Операция выполнена от лица владельца.



-- Для корректной работы тестов на уровень конфиденциальности, принудительно зададим 
-- известным медкартам минимальный и максимальный уровни конфиденциальности 
RESET ROLE;
UPDATE app.patient_records 
SET conf_level_id = (SELECT id FROM ref.confidentiality_levels WHERE level_code = 'BASIC_REG')
WHERE patient_id = (SELECT id FROM app.patients WHERE snils = '111-222-333 44');

UPDATE app.patient_records 
SET conf_level_id = (SELECT id FROM ref.confidentiality_levels WHERE level_code = 'SPECIAL_MED')
WHERE patient_id = (SELECT id FROM app.patients WHERE snils = '111-222-333 45');


-- КЕЙС 9 [Негативный]: grant_department_access – недостаточный уровень допуска медкарты
SET ROLE app_writer;
SELECT app.grant_department_access(
    (SELECT id FROM app.patient_records WHERE conf_level_id = (SELECT id FROM ref.confidentiality_levels WHERE level_code = 'BASIC_REG') LIMIT 1),
    (SELECT id FROM ref.medical_departments WHERE required_conf_level = (SELECT id FROM ref.confidentiality_levels WHERE level_code = 'SPECIAL_MED') LIMIT 1)
);
-- Ожидание: FALSE (Функция перехватит ошибку "Недостаточный уровень допуска медкарты для предоставления доступа отделению").


-- КЕЙС 10 [Позитивный]: grant_department_access – успешная выдача доступа отделению
SET ROLE app_writer;
SELECT app.grant_department_access(
    (SELECT id FROM app.patient_records WHERE conf_level_id = (SELECT id FROM ref.confidentiality_levels WHERE level_code = 'SPECIAL_MED') LIMIT 1),
    (SELECT id FROM ref.medical_departments WHERE required_conf_level = (SELECT id FROM ref.confidentiality_levels WHERE level_code = 'BASIC_REG') LIMIT 1)
);
-- Ожидание: TRUE (Доступ предоставлен, так как SPECIAL_MED > BASIC_REG).


-- КЕЙС 11 [Негативный]: register_diagnosis – пустой хэш диагноза или неверная категория
SET ROLE app_writer;
SELECT app.register_diagnosis(
    (SELECT id FROM app.patient_records WHERE is_active = true LIMIT 1),
    (SELECT id FROM ref.diagnosis_categories LIMIT 1),
    '', -- Нарушение бизнес-логики: пустой хэш диагноза
    '\xDEADBEEF'::bytea
);
-- Ожидание: FALSE (Ошибка "Хэш кода диагноза не может быть пустым").


-- КЕЙС 12 [Позитивный]: register_diagnosis – успешная регистрация клинического диагноза
SET ROLE app_writer;

SELECT app.register_diagnosis(
    (SELECT id FROM app.patient_records WHERE is_active = true LIMIT 1),
    3,
    'a1b2c3d4e5f67890abcdef1234567890abcdef1234567890abcdef1234567890',
    '\xDEADBEEF01020304'::bytea
);

-- Ожидание: TRUE (Запись диагноза успешно добавлена или обновлена через UPSERT).


-- КЕЙС 13 [Позитивный]: Проверка журнала вызовов для новых функций (аудитор)
SET ROLE auditor;
SELECT 
    call_time, 
    function_name, 
    success, 
    error_message 
FROM audit.function_calls 
WHERE function_name IN ('app.grant_department_access', 'app.register_diagnosis')
ORDER BY call_time DESC 
LIMIT 4;
-- Ожидание: 4 новые записи. Две с success = false (и текстами бизнес-ошибок), две с success = true.

RESET ROLE;







-- Таблица с ограничением CHECK (проверка сроков действия согласий на обработку ПДн)
CREATE TABLE app.test_consents_check (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_number VARCHAR(50) NOT NULL,
    issue_date DATE NOT NULL,
    expiry_date DATE,
    is_verified BOOLEAN DEFAULT false,
    CONSTRAINT chk_consent_dates_and_status CHECK (
        (expiry_date > issue_date OR expiry_date IS NULL)
        AND (NOT is_verified OR expiry_date IS NOT NULL)
        AND (expiry_date IS NULL OR (expiry_date - issue_date) <= 7305)
    )
);


-- Таблица без CHECK-ограничения (проверка через триггер)
CREATE TABLE app.test_consents_trigger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_number VARCHAR(50) NOT NULL,
    issue_date DATE NOT NULL,
    expiry_date DATE,
    is_verified BOOLEAN DEFAULT false
);

-- Триггерная функция валидации согласий на обработку ПДн
CREATE OR REPLACE FUNCTION app.fn_validate_consent_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Проверка согласованности дат
    IF NEW.expiry_date IS NOT NULL AND NEW.expiry_date <= NEW.issue_date THEN
        RAISE EXCEPTION 'Ошибка валидации: expiry_date (%) должна быть позже issue_date (%)', 
            NEW.expiry_date, NEW.issue_date
            USING ERRCODE = 'check_violation';
    END IF;

    -- Проверка наличия срока действия для верифицированных согласий
    IF NEW.is_verified AND NEW.expiry_date IS NULL THEN
        RAISE EXCEPTION 'Ошибка валидации: верифицированное согласие обязано иметь дату окончания действия'
            USING ERRCODE = 'not_null_violation';
    END IF;

    -- Проверка максимального срока действия согласия
    IF NEW.expiry_date IS NOT NULL AND (NEW.expiry_date - NEW.issue_date) > 7305 THEN
        RAISE EXCEPTION 'Ошибка валидации: срок действия согласия не может превышать 20 лет (7305 дней)'
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

-- Назначение BEFORE-триггера
CREATE TRIGGER trg_validate_consent_rules
BEFORE INSERT OR UPDATE ON app.test_consents_trigger
FOR EACH ROW
EXECUTE FUNCTION app.fn_validate_consent_trigger();



-- Замер 1: Массовая вставка 10 000 строк с CHECK-ограничением
DO $$
DECLARE
    v_start TIMESTAMPTZ;
    v_duration NUMERIC;
BEGIN
    TRUNCATE TABLE app.test_consents_check;
    v_start := clock_timestamp();

    INSERT INTO app.test_consents_check (document_number, issue_date, expiry_date, is_verified)
    SELECT
        'CONSENT-CHK-' || i,
        '2022-01-01'::date + (i % 365),
        '2022-01-01'::date + (i % 365) + 3650,
        (i % 2 = 0)
    FROM generate_series(1, 10000) AS i;

    v_duration := 1000 * EXTRACT(EPOCH FROM (clock_timestamp() - v_start));
    RAISE NOTICE 'Время выполнения вставки 10 000 строк (CHECK): % мс', round(v_duration, 2);
END;
$$;

-- Замер 2: Массовая вставка 10 000 строк с валидацией через ТРИГГЕР
DO $$
DECLARE
    v_start TIMESTAMPTZ;
    v_duration NUMERIC;
BEGIN
    TRUNCATE TABLE app.test_consents_trigger;
    v_start := clock_timestamp();

    INSERT INTO app.test_consents_trigger (document_number, issue_date, expiry_date, is_verified)
    SELECT
        'CONSENT-TRG-' || i,
        '2022-01-01'::date + (i % 365),
        '2022-01-01'::date + (i % 365) + 3650,
        (i % 2 = 0)
    FROM generate_series(1, 10000) AS i;

    v_duration := 1000 * EXTRACT(EPOCH FROM (clock_timestamp() - v_start));
    RAISE NOTICE 'Время выполнения вставки 10 000 строк (TRIGGER): % мс', round(v_duration, 2);
END;
$$;