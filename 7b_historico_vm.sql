/* =====================================================================
   PROYECTO INTEGRADOR - BASES DE DATOS II
   TurismoUQ: plataforma de reservas de alojamientos en el Quindío
   ---------------------------------------------------------------------
   Archivo   : 7b_historico_vm.sql
   Entrega   : 2 - Histórico en tablespace propio y vista materializada
   Ejecutar  : como TURISMOUQ
   Requiere  : 7a_tablespace_system.sql ejecutado antes como SYSTEM,
               además de 2_DDL.sql, 3_cargue_datos.sql y 5_paquete.sql
   Motor     : Oracle Database 21c XE
   ---------------------------------------------------------------------
   CONTENIDO
     0. Verificación previa: que 7a ya se haya ejecutado
     1. Tabla RESERVA_HISTORICO en TS_HISTORICO_RESERVAS
     2. Archivo de las reservas cerradas
     3. Vista materializada MV_OCUPACION_MENSUAL
     4. Refresco programado con DBMS_SCHEDULER
     5. Verificación

   CÓMO EJECUTARLO
   Conectado como TURISMOUQ, ejecutar todo con F5. Es re-ejecutable:
   la tabla, la vista y el job se borran y se vuelven a crear.

   SI APARECE UN ERROR
   Leer el PRIMER error de la salida. Si es el -20902 de la sección 0,
   falta ejecutar 7a como SYSTEM; los errores que vienen después son
   consecuencia de ese.
   ===================================================================== */

SET SERVEROUTPUT ON SIZE UNLIMITED


/* =====================================================================
   0. VERIFICACIÓN PREVIA
   ---------------------------------------------------------------------
   Comprueba que el script 7a ya dejó listo lo que este necesita:
   cuota en el tablespace y los dos privilegios.
   ===================================================================== */
DECLARE
  v_faltantes VARCHAR2(400);
  v_n         PLS_INTEGER;
BEGIN
  IF USER <> 'TURISMOUQ' THEN
    v_faltantes := v_faltantes || ' conectarse como TURISMOUQ (ahora es ' || USER || ');';
  END IF;

  SELECT COUNT(*) INTO v_n
  FROM   user_ts_quotas
  WHERE  tablespace_name = 'TS_HISTORICO_RESERVAS';
  IF v_n = 0 THEN
    v_faltantes := v_faltantes || ' cuota en TS_HISTORICO_RESERVAS;';
  END IF;

  SELECT COUNT(*) INTO v_n FROM session_privs WHERE privilege = 'CREATE MATERIALIZED VIEW';
  IF v_n = 0 THEN
    v_faltantes := v_faltantes || ' privilegio CREATE MATERIALIZED VIEW;';
  END IF;

  SELECT COUNT(*) INTO v_n FROM session_privs WHERE privilege = 'CREATE JOB';
  IF v_n = 0 THEN
    v_faltantes := v_faltantes || ' privilegio CREATE JOB;';
  END IF;

  IF v_faltantes IS NOT NULL THEN
    RAISE_APPLICATION_ERROR(-20902,
      'Falta:' || v_faltantes || ' ejecute primero 7a_tablespace_system.sql como SYSTEM ' ||
      '(y reconecte TURISMOUQ si estaba abierta). Los errores siguientes son consecuencia de este.');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Verificación previa OK: tablespace con cuota y privilegios listos.');
END;
/

/* =====================================================================
   1. TABLA RESERVA_HISTORICO
   ---------------------------------------------------------------------
   Una fila por reserva cerrada, con sus totales ya calculados. Es una
   tabla desnormalizada a propósito: el histórico se consulta para
   reportes, y así no hay que volver a unir siete tablas cada vez.
   Los totales quedan como estaban al archivar (no cambian después).

   Sin claves foráneas: el histórico debe sobrevivir aunque en el
   futuro se depuren las tablas operativas (mismo criterio que
   AUDITORIA_TARIFA).
   ===================================================================== */
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE reserva_historico PURGE';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -942 THEN RAISE; END IF;   -- -942: la tabla no existía
END;
/

CREATE TABLE reserva_historico (
  id_reserva       NUMBER(10)    NOT NULL,
  id_cliente       NUMBER(8)     NOT NULL,
  id_alojamiento   NUMBER(6)     NOT NULL,
  id_municipio     NUMBER(4)     NOT NULL,
  fecha_reserva    DATE          NOT NULL,
  fecha_checkin    DATE          NOT NULL,
  fecha_checkout   DATE          NOT NULL,
  estado           VARCHAR2(10)  NOT NULL,
  num_habitaciones NUMBER(3)     NOT NULL,
  noches           NUMBER(5)     NOT NULL,
  valor_estadia    NUMBER(14,2)  NOT NULL,
  valor_servicios  NUMBER(14,2)  NOT NULL,
  total_pagado     NUMBER(14,2)  NOT NULL,
  monto_reembolso  NUMBER(14,2)  NOT NULL,
  fecha_archivo    DATE          DEFAULT SYSDATE NOT NULL,
  CONSTRAINT pk_reserva_historico     PRIMARY KEY (id_reserva)
                                      USING INDEX TABLESPACE ts_historico_reservas,
  CONSTRAINT ck_reshist_estado        CHECK (estado IN ('COMPLETADA', 'CANCELADA')),
  CONSTRAINT ck_reshist_fechas        CHECK (fecha_checkout > fecha_checkin),
  CONSTRAINT ck_reshist_no_neg        CHECK (num_habitaciones >= 1 AND noches >= 1
                                             AND valor_estadia >= 0 AND valor_servicios >= 0
                                             AND total_pagado >= 0 AND monto_reembolso >= 0)
)
TABLESPACE ts_historico_reservas;

COMMENT ON TABLE  reserva_historico                  IS 'Reservas cerradas (completadas o canceladas) archivadas con sus totales. Vive en TS_HISTORICO_RESERVAS.';
COMMENT ON COLUMN reserva_historico.noches           IS 'Noches-habitación: suma de las noches de todas sus líneas.';
COMMENT ON COLUMN reserva_historico.valor_estadia    IS 'Suma de RESERVA_NOCHE.valor_noche de la reserva (precio congelado, RN9).';
COMMENT ON COLUMN reserva_historico.valor_servicios  IS 'Suma de cantidad x precio_unitario de sus servicios.';
COMMENT ON COLUMN reserva_historico.total_pagado     IS 'Pagos EXITOSO y REEMBOLSADO (dinero que llegó a recibirse), como en V_INGRESO_RECONOCIDO.';
COMMENT ON COLUMN reserva_historico.monto_reembolso  IS 'Reembolso de la cancelación (0 si no fue cancelada o no tuvo reembolso).';
COMMENT ON COLUMN reserva_historico.fecha_archivo    IS 'Momento en que la reserva se copió al histórico.';


/* =====================================================================
   2. ARCHIVO DE LAS RESERVAS CERRADAS
   ---------------------------------------------------------------------
   Copia al histórico las reservas COMPLETADA o CANCELADA cuya salida
   fue antes del corte. El corte es el 01/01/2026: los años 2024 y
   2025 completos, ya cerrados y liquidados.

   COPIAR, NO MOVER
   En producción, después de copiar se borrarían de las tablas
   operativas. Aquí NO se borran, porque las consultas de la Entrega 1
   y la liquidación usan esos datos. Con MERGE, ejecutar el archivo
   otra vez solo agrega las reservas que falten.
   ===================================================================== */
MERGE INTO reserva_historico h
USING (
  SELECT r.id_reserva,
         r.id_cliente,
         r.id_alojamiento,
         a.id_municipio,
         r.fecha_reserva,
         r.fecha_checkin,
         r.fecha_checkout,
         r.estado,
         lin.num_habitaciones,
         lin.noches,
         NVL(est.valor, 0)              AS valor_estadia,
         NVL(ser.valor, 0)              AS valor_servicios,
         NVL(pag.valor, 0)              AS total_pagado,
         NVL(can.monto_reembolso, 0)    AS monto_reembolso
  FROM   reserva r
  JOIN   alojamiento a ON a.id_alojamiento = r.id_alojamiento
  JOIN  (SELECT id_reserva,
                COUNT(*)                            AS num_habitaciones,
                SUM(fecha_checkout - fecha_checkin) AS noches
         FROM   reserva_habitacion
         GROUP  BY id_reserva) lin ON lin.id_reserva = r.id_reserva
  LEFT JOIN (SELECT rh.id_reserva, SUM(rn.valor_noche) AS valor
             FROM   reserva_noche rn
             JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
             GROUP  BY rh.id_reserva) est ON est.id_reserva = r.id_reserva
  LEFT JOIN (SELECT id_reserva, SUM(cantidad * precio_unitario) AS valor
             FROM   reserva_servicio
             GROUP  BY id_reserva) ser ON ser.id_reserva = r.id_reserva
  LEFT JOIN (SELECT id_reserva, SUM(monto) AS valor
             FROM   pago
             WHERE  estado IN ('EXITOSO', 'REEMBOLSADO')
             GROUP  BY id_reserva) pag ON pag.id_reserva = r.id_reserva
  LEFT JOIN cancelacion can ON can.id_reserva = r.id_reserva
  WHERE  r.estado IN ('COMPLETADA', 'CANCELADA')
  AND    r.fecha_checkout < DATE '2026-01-01'          -- corte del archivo
) x
ON (h.id_reserva = x.id_reserva)
WHEN NOT MATCHED THEN INSERT
  (id_reserva, id_cliente, id_alojamiento, id_municipio, fecha_reserva,
   fecha_checkin, fecha_checkout, estado, num_habitaciones, noches,
   valor_estadia, valor_servicios, total_pagado, monto_reembolso)
VALUES
  (x.id_reserva, x.id_cliente, x.id_alojamiento, x.id_municipio, x.fecha_reserva,
   x.fecha_checkin, x.fecha_checkout, x.estado, x.num_habitaciones, x.noches,
   x.valor_estadia, x.valor_servicios, x.total_pagado, x.monto_reembolso);

COMMIT;


/* =====================================================================
   3. VISTA MATERIALIZADA MV_OCUPACION_MENSUAL
   ---------------------------------------------------------------------
   QUÉ PRECALCULA
   Una fila por alojamiento y mes, con:
     noches_vendidas    = noches de reservas CONFIRMADA o COMPLETADA
     noches_disponibles = habitaciones del alojamiento x días del mes
     ocupacion_pct      = noches_vendidas / noches_disponibles x 100
   Es la MISMA definición de la consulta 1 de la Entrega 1, así que
   ambas dan los mismos números (la prueba 5.3 lo comprueba).

   Incluye los meses sin ventas (ocupación 0 %): los meses salen del
   rango completo de RESERVA_NOCHE y se cruzan con todos los
   alojamientos.

   CÓMO AGREGARLA
   Para un municipio o un tipo, se suman noches y se divide al final:
       SUM(noches_vendidas) / SUM(noches_disponibles)
   Promediar ocupacion_pct estaría mal, porque un hotel de 40
   habitaciones pesaría lo mismo que una finca de 3.

   POLÍTICA DE REFRESCO: COMPLETE, ON DEMAND, CADA NOCHE A LAS 2:00
     - Por qué no FAST (incremental): exige materialized view logs en
       todas las tablas base y Oracle no lo permite con esta consulta
       (uniones externas, generación de meses con CONNECT BY y
       subconsultas agregadas).
     - Por qué no ON COMMIT: recalcularía la vista dentro de cada
       transacción que confirme una reserva. Haría más lenta justo la
       operación más frecuente del negocio, para un reporte que la
       gerencia consulta por mes.
     - Por qué cada noche: la ocupación mensual es un indicador de
       gestión; un día de desfase no cambia ninguna decisión. Un
       refresco completo recorre ~80.000 noches y tarda segundos, a una
       hora sin usuarios.
     - Si se necesita el dato al instante (por ejemplo, en la
       sustentación), se refresca a mano:
           EXEC DBMS_MVIEW.REFRESH('MV_OCUPACION_MENSUAL', 'C');
   ===================================================================== */
BEGIN
  EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW mv_ocupacion_mensual';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -12003 THEN RAISE; END IF;  -- -12003: la vista no existía
END;
/

CREATE MATERIALIZED VIEW mv_ocupacion_mensual
  BUILD IMMEDIATE
  REFRESH COMPLETE ON DEMAND
AS
SELECT a.id_alojamiento,
       a.nombre_comercial                                     AS alojamiento,
       a.id_municipio,
       m.nombre                                               AS municipio,
       a.id_tipo_alojamiento,
       ti.nombre                                              AS tipo_alojamiento,
       me.mes_inicio,
       EXTRACT(YEAR  FROM me.mes_inicio)                      AS anio,
       EXTRACT(MONTH FROM me.mes_inicio)                      AS mes,
       cap.habitaciones,
       EXTRACT(DAY FROM LAST_DAY(me.mes_inicio))              AS dias_mes,
       cap.habitaciones * EXTRACT(DAY FROM LAST_DAY(me.mes_inicio)) AS noches_disponibles,
       NVL(v.noches_vendidas, 0)                              AS noches_vendidas,
       ROUND(100 * NVL(v.noches_vendidas, 0)
                 / (cap.habitaciones * EXTRACT(DAY FROM LAST_DAY(me.mes_inicio))), 2) AS ocupacion_pct
FROM   alojamiento a
JOIN   municipio        m  ON m.id_municipio         = a.id_municipio
JOIN   tipo_alojamiento ti ON ti.id_tipo_alojamiento = a.id_tipo_alojamiento
-- Habitaciones de cada alojamiento
JOIN  (SELECT id_alojamiento, COUNT(*) AS habitaciones
       FROM   habitacion
       GROUP  BY id_alojamiento) cap ON cap.id_alojamiento = a.id_alojamiento
-- Todos los meses entre la primera y la última noche registradas
CROSS JOIN (SELECT ADD_MONTHS(rango.ini, LEVEL - 1) AS mes_inicio
            FROM  (SELECT TRUNC(MIN(fecha_noche), 'MM') AS ini,
                          TRUNC(MAX(fecha_noche), 'MM') AS fin
                   FROM   reserva_noche) rango
            CONNECT BY LEVEL <= MONTHS_BETWEEN(rango.fin, rango.ini) + 1) me
-- Noches vendidas por alojamiento y mes
LEFT JOIN (SELECT r.id_alojamiento,
                  TRUNC(rn.fecha_noche, 'MM') AS mes_inicio,
                  COUNT(*)                    AS noches_vendidas
           FROM   reserva_noche      rn
           JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
           JOIN   reserva            r  ON r.id_reserva      = rh.id_reserva
           WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
           GROUP  BY r.id_alojamiento, TRUNC(rn.fecha_noche, 'MM')) v
       ON  v.id_alojamiento = a.id_alojamiento
       AND v.mes_inicio     = me.mes_inicio;

COMMENT ON MATERIALIZED VIEW mv_ocupacion_mensual IS
  'Ocupación mensual por alojamiento (misma definición que la consulta 1). Refresco COMPLETE ON DEMAND, programado cada noche a las 2:00.';


/* =====================================================================
   4. REFRESCO PROGRAMADO
   ---------------------------------------------------------------------
   Job de DBMS_SCHEDULER que refresca la vista todos los días a las
   2:00 a.m. Si ya existía, se borra y se vuelve a crear.
   ===================================================================== */
BEGIN
  BEGIN
    DBMS_SCHEDULER.DROP_JOB(job_name => 'JOB_REFRESCO_OCUPACION', force => TRUE);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE != -27475 THEN RAISE; END IF;  -- -27475: el job no existía
  END;

  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_REFRESCO_OCUPACION',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN DBMS_MVIEW.REFRESH(''MV_OCUPACION_MENSUAL'', ''C''); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY; BYHOUR=2; BYMINUTE=0; BYSECOND=0',
    enabled         => TRUE,
    comments        => 'Refresco completo nocturno de MV_OCUPACION_MENSUAL (Entrega 2).');
END;
/


/* =====================================================================
   5. VERIFICACIÓN
   ===================================================================== */

-- Dónde quedó cada tabla: RESERVA en USERS, RESERVA_HISTORICO en el tablespace propio
SELECT table_name, tablespace_name
FROM   user_tables
WHERE  table_name IN ('RESERVA', 'RESERVA_HISTORICO')
ORDER  BY table_name;

-- Cuota de TURISMOUQ en el tablespace del histórico
SELECT tablespace_name,
       ROUND(bytes / 1024 / 1024, 2) AS usado_mb,
       max_bytes / 1024 / 1024       AS cuota_mb
FROM   user_ts_quotas
WHERE  tablespace_name = 'TS_HISTORICO_RESERVAS';

-- Contenido del histórico
SELECT estado, COUNT(*) AS reservas, SUM(valor_estadia) AS valor_estadias
FROM   reserva_historico
GROUP  BY estado;

-- Estado de la vista materializada
SELECT mview_name, refresh_mode, refresh_method, build_mode,
       TO_CHAR(last_refresh_date, 'DD/MM/YYYY HH24:MI:SS') AS ultimo_refresco
FROM   user_mviews
WHERE  mview_name = 'MV_OCUPACION_MENSUAL';

-- Job programado
SELECT job_name, enabled, state, repeat_interval,
       TO_CHAR(next_run_date, 'DD/MM/YYYY HH24:MI') AS proxima_ejecucion
FROM   user_scheduler_jobs
WHERE  job_name = 'JOB_REFRESCO_OCUPACION';

/* Fin del script 7b */
