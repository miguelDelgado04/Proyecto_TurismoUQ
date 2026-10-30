/* =====================================================================
   PROYECTO INTEGRADOR - BASES DE DATOS II
   TurismoUQ: plataforma de reservas de alojamientos en el Quindío
   ---------------------------------------------------------------------
   Archivo   : 8_pruebas.sql
   Entrega   : 2 - Evidencia de prueba de cada componente
   Requiere  : 2_DDL.sql, 3_cargue_datos.sql, 5_paquete.sql,
               6_disparadores.sql, 7a_tablespace_system.sql y
               7b_historico_vm.sql ejecutados
   Motor     : Oracle Database 21c XE
   ---------------------------------------------------------------------
   CONTENIDO
     1. fn_valor_estadia y fn_tarifa_noche
     2. sp_crear_reserva 
     3. Disparadores (solape y auditoría) 
     4. Cursor de liquidación mensual 
     5. Tablespace y vista materializada 

   CÓMO EJECUTARLO
   Conectado como TURISMOUQ, ejecutar todo con F5. Cada prueba imprime
   OK o FALLA en la salida de DBMS_OUTPUT. Capturar la salida de cada
   sección como evidencia.

   QUÉ DEJAN LAS PRUEBAS EN LA BASE
     Secciones 1, 2 y 3 : nada. Las reservas y los cambios de tarifas
                          de prueba terminan con ROLLBACK.
     Sección 4          : las liquidaciones de 01/2024 a 09/2026 en
                          LIQUIDACION_MENSUAL (es su resultado esperado;
                          volver a ejecutar solo las actualiza).
     Sección 5.4        : nada. DBMS_MVIEW.REFRESH confirma la reserva de
                          prueba, así que la sección la borra al final.

   FECHAS
   Las secciones 2, 3 y 5.4 usan reservas del 08/12/2026 al
   13/12/2026. Si se ejecutan después del 08/12/2026, cambiar c_in y
   c_out por fechas futuras anteriores al 10/01/2027.
   ===================================================================== */

SET SERVEROUTPUT ON SIZE UNLIMITED
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';


/* =====================================================================
   1. FN_VALOR_ESTADIA Y FN_TARIFA_NOCHE                  
   ===================================================================== */

/* ---------------------------------------------------------------------
   1.1 Casos válidos
   Cada caso compara el valor de la función contra un cálculo
   independiente hecho noche por noche (una fila por noche, con la
   temporada que la contiene). Si coinciden, la prueba es OK.

   Fechas elegidas según el calendario de temporadas de la carga:
     a) 10-14 feb 2025 : todo en BAJA                     -> 1 temporada
     b) 17-23 jun 2025 : MEDIA hasta el 19, MITAD DE AÑO
                         (ALTA) desde el 20               -> 2 temporadas
     c) 21-29 mar 2026 : PUENTE DE SAN JOSÉ (ALTA), MEDIA
                         del 23 al 26, SEMANA SANTA (ALTA) -> 3 temporadas
     d) 28 dic 2025 - 15 ene 2026 : FIN DE AÑO (ALTA) hasta el 11,
                         BAJA desde el 12; cruza de año   -> 2 temporadas
     e) 16-17 ago 2025 : una sola noche
   --------------------------------------------------------------------- */
DECLARE
  v_hab    habitacion.id_habitacion%TYPE;
  v_fallas PLS_INTEGER := 0;

  PROCEDURE probar (p_desc VARCHAR2, p_in DATE, p_out DATE) IS
    v_funcion  NUMBER;
    v_esperado NUMBER;
    v_noches   PLS_INTEGER;
    v_temps    PLS_INTEGER;
  BEGIN
    v_funcion := pkg_turismouq.fn_valor_estadia(v_hab, p_in, p_out);

    -- Cálculo independiente: una fila por noche.
    SELECT NVL(SUM(ta.valor_noche), 0), COUNT(*), COUNT(DISTINCT t.id_temporada)
    INTO   v_esperado, v_noches, v_temps
    FROM  (SELECT p_in + LEVEL - 1 AS noche
           FROM   dual
           CONNECT BY LEVEL <= p_out - p_in) n
    JOIN   temporada t  ON n.noche BETWEEN t.fecha_inicio AND t.fecha_fin
    JOIN   tarifa    ta ON ta.id_temporada  = t.id_temporada
                       AND ta.id_habitacion = v_hab;

    IF v_funcion = v_esperado THEN
      DBMS_OUTPUT.PUT_LINE('OK    ' || RPAD(p_desc, 34) ||
        ' noches=' || v_noches || ' temporadas=' || v_temps ||
        ' valor=' || TO_CHAR(v_funcion, 'FM999G999G990D00'));
    ELSE
      v_fallas := v_fallas + 1;
      DBMS_OUTPUT.PUT_LINE('FALLA ' || RPAD(p_desc, 34) ||
        ' funcion=' || v_funcion || ' esperado=' || v_esperado);
    END IF;
  END probar;
BEGIN
  SELECT MIN(id_habitacion) INTO v_hab FROM habitacion;
  DBMS_OUTPUT.PUT_LINE('1.1 Casos válidos de fn_valor_estadia (habitación ' || v_hab || ')');
  DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');

  probar('a) una temporada (BAJA)',        DATE '2025-02-10', DATE '2025-02-14');
  probar('b) MEDIA -> ALTA',               DATE '2025-06-17', DATE '2025-06-23');
  probar('c) ALTA -> MEDIA -> ALTA',       DATE '2026-03-21', DATE '2026-03-29');
  probar('d) cruce de año ALTA -> BAJA',   DATE '2025-12-28', DATE '2026-01-15');
  probar('e) una sola noche',              DATE '2025-08-16', DATE '2025-08-17');

  DBMS_OUTPUT.PUT_LINE('Resultado: ' || CASE v_fallas WHEN 0 THEN 'todas OK'
                                         ELSE v_fallas || ' falla(s)' END);
END;
/

/* ---------------------------------------------------------------------
   1.2 Desglose del caso b) noche por noche
   Evidencia visual de la decisión de diseño: la misma estadía cobra
   tres noches con la tarifa MEDIA y tres con la ALTA. La última fila
   muestra que la suma coincide con la función.
   --------------------------------------------------------------------- */
WITH p AS (
  SELECT (SELECT MIN(id_habitacion) FROM habitacion) AS id_hab,
         DATE '2025-06-17' AS f_in,
         DATE '2025-06-23' AS f_out
  FROM   dual
),
noches AS (
  SELECT p.id_hab, p.f_in + LEVEL - 1 AS noche
  FROM   p
  CONNECT BY LEVEL <= p.f_out - p.f_in
)
SELECT TO_CHAR(n.noche, 'DD/MM/YYYY')  AS noche,
       tt.nombre                       AS tipo,
       t.nombre                        AS temporada,
       ta.valor_noche                  AS valor_noche
FROM   noches n
JOIN   temporada      t  ON n.noche BETWEEN t.fecha_inicio AND t.fecha_fin
JOIN   tipo_temporada tt ON tt.id_tipo_temporada = t.id_tipo_temporada
JOIN   tarifa         ta ON ta.id_temporada  = t.id_temporada
                        AND ta.id_habitacion = n.id_hab
UNION ALL
SELECT 'TOTAL', NULL, 'fn_valor_estadia',
       pkg_turismouq.fn_valor_estadia(p.id_hab, p.f_in, p.f_out)
FROM   p
ORDER  BY 1;

/* ---------------------------------------------------------------------
   1.3 Casos de error
   Cada llamada debe lanzar el código propio esperado. Si no lanza
   error, o lanza otro distinto, la prueba es FALLA.
   --------------------------------------------------------------------- */
DECLARE
  v_hab    habitacion.id_habitacion%TYPE;
  v_fallas PLS_INTEGER := 0;

  PROCEDURE probar_error (p_desc VARCHAR2, p_id_hab NUMBER,
                          p_in DATE, p_out DATE, p_codigo PLS_INTEGER) IS
    v_valor NUMBER;
  BEGIN
    v_valor := pkg_turismouq.fn_valor_estadia(p_id_hab, p_in, p_out);
    v_fallas := v_fallas + 1;
    DBMS_OUTPUT.PUT_LINE('FALLA ' || RPAD(p_desc, 32) ||
      ' no lanzó error (valor=' || v_valor || ')');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = p_codigo THEN
        DBMS_OUTPUT.PUT_LINE('OK    ' || RPAD(p_desc, 32) || ' ' || SQLERRM);
      ELSE
        v_fallas := v_fallas + 1;
        DBMS_OUTPUT.PUT_LINE('FALLA ' || RPAD(p_desc, 32) ||
          ' esperaba ' || p_codigo || ', obtuvo ' || SQLERRM);
      END IF;
  END probar_error;
BEGIN
  SELECT MIN(id_habitacion) INTO v_hab FROM habitacion;
  DBMS_OUTPUT.PUT_LINE('1.3 Casos de error de fn_valor_estadia');
  DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');

  probar_error('checkout igual al checkin',  v_hab, DATE '2025-06-17', DATE '2025-06-17', -20010);
  probar_error('checkout antes del checkin', v_hab, DATE '2025-06-23', DATE '2025-06-17', -20010);
  probar_error('fecha nula',                 v_hab, NULL,              DATE '2025-06-17', -20010);
  probar_error('habitación inexistente',     -1,    DATE '2025-06-17', DATE '2025-06-23', -20011);
  probar_error('fechas sin temporada (2030)', v_hab, DATE '2030-01-01', DATE '2030-01-05', -20012);
  probar_error('estadía que sale del calendario', v_hab, DATE '2027-01-08', DATE '2027-01-14', -20012);

  DBMS_OUTPUT.PUT_LINE('Resultado: ' || CASE v_fallas WHEN 0 THEN 'todas OK'
                                         ELSE v_fallas || ' falla(s)' END);
END;
/

/* ---------------------------------------------------------------------
   1.4 Prueba masiva contra RESERVA_NOCHE
   Para cada línea de RESERVA_HABITACION de la carga, el valor de la
   función debe ser igual a la suma de sus noches en RESERVA_NOCHE.
   Las dos columnas de líneas deben ser iguales y la de diferencias
   debe dar 0. La última columna muestra cuántas de esas líneas cruzan
   más de una temporada.
   --------------------------------------------------------------------- */
WITH comparacion AS (
  SELECT rh.id_reserva_hab,
         pkg_turismouq.fn_valor_estadia(rh.id_habitacion,
                                        rh.fecha_checkin,
                                        rh.fecha_checkout) AS valor_funcion,
         (SELECT SUM(rn.valor_noche)
          FROM   reserva_noche rn
          WHERE  rn.id_reserva_hab = rh.id_reserva_hab)   AS valor_guardado,
         (SELECT COUNT(DISTINCT ta.id_temporada)
          FROM   reserva_noche rn
          JOIN   tarifa ta ON ta.id_tarifa = rn.id_tarifa
          WHERE  rn.id_reserva_hab = rh.id_reserva_hab)   AS temporadas
  FROM   reserva_habitacion rh
)
SELECT COUNT(*)                                                         AS lineas,
       SUM(CASE WHEN valor_funcion = valor_guardado THEN 1 ELSE 0 END)  AS lineas_que_coinciden,
       SUM(CASE WHEN valor_funcion <> valor_guardado THEN 1 ELSE 0 END) AS diferencias,
       SUM(CASE WHEN temporadas > 1 THEN 1 ELSE 0 END)                  AS lineas_que_cruzan_temporadas
FROM   comparacion;

/* ---------------------------------------------------------------------
   1.5 fn_tarifa_noche
   Sumar fn_tarifa_noche noche por noche debe dar lo mismo que
   fn_valor_estadia. Se usa el caso c), que atraviesa tres temporadas.
   --------------------------------------------------------------------- */
DECLARE
  v_hab    habitacion.id_habitacion%TYPE;
  v_in     DATE := DATE '2026-03-21';
  v_out    DATE := DATE '2026-03-29';
  v_tarifa tarifa%ROWTYPE;
  v_suma   NUMBER := 0;
  v_total  NUMBER;
BEGIN
  SELECT MIN(id_habitacion) INTO v_hab FROM habitacion;
  DBMS_OUTPUT.PUT_LINE('1.5 fn_tarifa_noche, habitación ' || v_hab ||
                       ', del ' || v_in || ' al ' || v_out);
  DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');

  FOR i IN 0 .. (v_out - v_in) - 1 LOOP
    v_tarifa := pkg_turismouq.fn_tarifa_noche(v_hab, v_in + i);
    v_suma   := v_suma + v_tarifa.valor_noche;
    DBMS_OUTPUT.PUT_LINE('  ' || TO_CHAR(v_in + i, 'DD/MM/YYYY') ||
                         '  id_tarifa=' || v_tarifa.id_tarifa ||
                         '  temporada=' || v_tarifa.id_temporada ||
                         '  valor=' || TO_CHAR(v_tarifa.valor_noche, 'FM999G999G990D00'));
  END LOOP;

  v_total := pkg_turismouq.fn_valor_estadia(v_hab, v_in, v_out);
  DBMS_OUTPUT.PUT_LINE(CASE WHEN v_suma = v_total THEN 'OK    ' ELSE 'FALLA ' END ||
                       'suma noche a noche=' || v_suma || '  fn_valor_estadia=' || v_total);
END;
/


/* =====================================================================
   2. SP_CREAR_RESERVA                                     
   ---------------------------------------------------------------------
   FECHAS DE PRUEBA
   Del 08/12/2026 al 13/12/2026: 3 noches en temporada MEDIA (8, 9 y
   10) y 2 en FIN DE AÑO 2026-2027, ALTA (11 y 12). La reserva de
   prueba cruza temporadas y debe quedar con tarifas distintas en
   RESERVA_NOCHE. Deben ser fechas futuras (el DDL no permite reservar
   con checkin en el pasado); si ya pasaron, cambiar c_in y c_out por
   otras anteriores al 10/01/2027.

   La habitación se elige sola: la primera con capacidad para 2 o más
   que esté libre en esas fechas. Todo termina con ROLLBACK: los datos
   de la carga quedan intactos.
   ===================================================================== */
DECLARE
  c_in     CONSTANT DATE := DATE '2026-12-08';
  c_out    CONSTANT DATE := DATE '2026-12-13';
  v_hab    habitacion.id_habitacion%TYPE;
  v_cap    habitacion.capacidad_max%TYPE;
  v_aloj   habitacion.id_alojamiento%TYPE;
  v_cli    cliente.id_cliente%TYPE;
  v_id     reserva.id_reserva%TYPE;
  v_id2    reserva.id_reserva%TYPE;
  v_n      NUMBER;
  v_m      NUMBER;
  v_fallas PLS_INTEGER := 0;

  PROCEDURE resultado (p_ok BOOLEAN, p_desc VARCHAR2, p_detalle VARCHAR2 DEFAULT NULL) IS
  BEGIN
    IF NOT p_ok THEN v_fallas := v_fallas + 1; END IF;
    DBMS_OUTPUT.PUT_LINE(CASE WHEN p_ok THEN 'OK    ' ELSE 'FALLA ' END ||
                         RPAD(p_desc, 36) || ' ' || p_detalle);
  END resultado;

  -- Llama al procedimiento esperando un error concreto y verifica que
  -- no haya quedado ninguna reserva a medio crear.
  PROCEDURE probar_error (p_desc VARCHAR2, p_cli NUMBER, p_hab NUMBER,
                          p_in DATE, p_out DATE, p_huesp NUMBER,
                          p_codigo PLS_INTEGER) IS
    v_res     reserva.id_reserva%TYPE;
    v_antes   PLS_INTEGER;
    v_despues PLS_INTEGER;
    v_cod     PLS_INTEGER;
    v_msg     VARCHAR2(512);
  BEGIN
    SELECT COUNT(*) INTO v_antes FROM reserva;
    pkg_turismouq.sp_crear_reserva(p_cli, p_hab, p_in, p_out, p_huesp, v_res);
    resultado(FALSE, p_desc, 'no lanzó error, creó la reserva ' || v_res);
  EXCEPTION
    WHEN OTHERS THEN
      v_cod := SQLCODE;
      v_msg := SQLERRM;
      SELECT COUNT(*) INTO v_despues FROM reserva;
      resultado(v_cod = p_codigo AND v_despues = v_antes, p_desc,
                v_msg || CASE WHEN v_despues <> v_antes
                              THEN ' [QUEDÓ UNA RESERVA A MEDIO CREAR]' END);
  END probar_error;

BEGIN
  IF TRUNC(SYSDATE) > c_in THEN
    DBMS_OUTPUT.PUT_LINE('Las fechas de prueba ya pasaron: cambie c_in y c_out.');
    RETURN;
  END IF;

  SELECT MIN(id_cliente) INTO v_cli FROM cliente;

  SELECT MIN(h.id_habitacion)
  INTO   v_hab
  FROM   habitacion h
  WHERE  h.capacidad_max >= 2
  AND    NOT EXISTS (SELECT 1
                     FROM   reserva_habitacion rh
                     JOIN   reserva r ON r.id_reserva = rh.id_reserva
                     WHERE  rh.id_habitacion = h.id_habitacion
                     AND    r.estado <> 'CANCELADA'
                     AND    rh.fecha_checkin < c_out + 2
                     AND    c_in < rh.fecha_checkout);

  SELECT capacidad_max, id_alojamiento INTO v_cap, v_aloj
  FROM   habitacion WHERE id_habitacion = v_hab;

  DBMS_OUTPUT.PUT_LINE('2. sp_crear_reserva  (cliente ' || v_cli || ', habitación ' ||
                       v_hab || ', capacidad ' || v_cap || ')');
  DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');

  -- 2.1 Caso válido -------------------------------------------------
  pkg_turismouq.sp_crear_reserva(v_cli, v_hab, c_in, c_out, 2, v_id);
  resultado(v_id IS NOT NULL, '2.1 reserva creada', 'id_reserva = ' || v_id);

  SELECT COUNT(*) INTO v_n FROM reserva
  WHERE  id_reserva = v_id AND estado = 'PENDIENTE' AND id_alojamiento = v_aloj
  AND    fecha_checkin = c_in AND fecha_checkout = c_out;
  resultado(v_n = 1, '    cabecera PENDIENTE y alojamiento', 'alojamiento ' || v_aloj);

  SELECT COUNT(*) INTO v_n FROM reserva_habitacion WHERE id_reserva = v_id;
  resultado(v_n = 1, '    una línea en RESERVA_HABITACION');

  SELECT COUNT(*), SUM(rn.valor_noche) INTO v_n, v_m
  FROM   reserva_noche rn
  JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
  WHERE  rh.id_reserva = v_id;
  resultado(v_n = c_out - c_in, '    una fila por noche', v_n || ' noches');
  resultado(v_m = pkg_turismouq.fn_valor_estadia(v_hab, c_in, c_out),
            '    total igual a fn_valor_estadia', TO_CHAR(v_m, 'FM999G999G990D00'));

  SELECT COUNT(DISTINCT ta.id_temporada) INTO v_n
  FROM   reserva_noche rn
  JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
  JOIN   tarifa ta             ON ta.id_tarifa      = rn.id_tarifa
  WHERE  rh.id_reserva = v_id;
  resultado(v_n = 2, '    noches en 2 temporadas', v_n || ' temporadas');

  FOR r IN (SELECT rn.fecha_noche, t.nombre AS temporada, rn.valor_noche
            FROM   reserva_noche rn
            JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
            JOIN   tarifa    ta ON ta.id_tarifa    = rn.id_tarifa
            JOIN   temporada t  ON t.id_temporada  = ta.id_temporada
            WHERE  rh.id_reserva = v_id
            ORDER  BY rn.fecha_noche) LOOP
    DBMS_OUTPUT.PUT_LINE('        ' || TO_CHAR(r.fecha_noche, 'DD/MM/YYYY') || '  ' ||
                         RPAD(r.temporada, 30) || TO_CHAR(r.valor_noche, 'FM999G999G990D00'));
  END LOOP;

  -- 2.2 Rango semiabierto: llegar el día en que sale el anterior -----
  pkg_turismouq.sp_crear_reserva(v_cli, v_hab, c_out, c_out + 2, 1, v_id2);
  resultado(v_id2 IS NOT NULL, '2.2 llegada el día de salida', 'id_reserva = ' || v_id2);

  -- 2.3 Excepciones propias ------------------------------------------
  DBMS_OUTPUT.PUT_LINE('2.3 Excepciones');
  probar_error('    checkout igual al checkin',  v_cli, v_hab, c_in,  c_in,      1, -20001);
  probar_error('    checkout antes del checkin', v_cli, v_hab, c_out, c_in,      1, -20001);
  probar_error('    checkin en el pasado',       v_cli, v_hab, DATE '2025-01-10',
                                                              DATE '2025-01-12',   1, -20001);
  probar_error('    capacidad excedida',         v_cli, v_hab, c_in + 20, c_in + 22, v_cap + 1, -20002);
  probar_error('    cero huéspedes',             v_cli, v_hab, c_in + 20, c_in + 22, 0, -20002);
  probar_error('    habitación no disponible',   v_cli, v_hab, c_in + 1, c_in + 3,   1, -20003);
  probar_error('    cliente inexistente',        -1,    v_hab, c_in + 20, c_in + 22, 1, -20004);
  probar_error('    habitación inexistente',     v_cli, -1,    c_in + 20, c_in + 22, 1, -20011);
  probar_error('    noches sin tarifa',          v_cli, v_hab, DATE '2027-01-08',
                                                              DATE '2027-01-14',   1, -20012);

  DBMS_OUTPUT.PUT_LINE('Resultado: ' || CASE v_fallas WHEN 0 THEN 'todas OK'
                                         ELSE v_fallas || ' falla(s)' END);
  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('ROLLBACK: reservas de prueba deshechas.');
END;
/


/* =====================================================================
   3. DISPARADORES                                        
   ===================================================================== */

/* ---------------------------------------------------------------------
   3.1 TRG_RESHAB_NO_SOLAPE
   Las líneas se insertan DIRECTAMENTE en RESERVA_HABITACION, sin pasar
   por sp_crear_reserva, para demostrar que el disparador protege la
   tabla aunque alguien se salte el procedimiento.

     a) INSERT que se cruza con otra reserva          -> -20020
     b) INSERT que llega el día de salida de la otra  -> se acepta
     c) UPDATE que mueve una línea a fechas ocupadas   -> -20020
        (un disparador de fila simple fallaría aquí con ORA-04091)
     d) INSERT ... SELECT de dos líneas que se cruzan
        entre sí en la misma sentencia                 -> -20020
     e) INSERT que se cruza con una reserva CANCELADA  -> se acepta
   En cada rechazo se verifica que la tabla quedó igual. Todo termina
   con ROLLBACK.
   --------------------------------------------------------------------- */
DECLARE
  c_in     CONSTANT DATE := DATE '2026-12-08';
  c_out    CONSTANT DATE := DATE '2026-12-13';
  v_hab    habitacion.id_habitacion%TYPE;
  v_aloj   habitacion.id_alojamiento%TYPE;
  v_cli    cliente.id_cliente%TYPE;
  v_id_a   reserva.id_reserva%TYPE;
  v_id_b   reserva.id_reserva%TYPE;
  v_id_c   reserva.id_reserva%TYPE;
  v_id_d   reserva.id_reserva%TYPE;
  v_linea  reserva_habitacion.id_reserva_hab%TYPE;
  v_antes  PLS_INTEGER;
  v_despues PLS_INTEGER;
  v_cod    PLS_INTEGER;
  v_msg    VARCHAR2(512);
  v_fallas PLS_INTEGER := 0;

  PROCEDURE resultado (p_ok BOOLEAN, p_desc VARCHAR2, p_detalle VARCHAR2 DEFAULT NULL) IS
  BEGIN
    IF NOT p_ok THEN v_fallas := v_fallas + 1; END IF;
    DBMS_OUTPUT.PUT_LINE(CASE WHEN p_ok THEN 'OK    ' ELSE 'FALLA ' END ||
                         RPAD(p_desc, 40) || ' ' || p_detalle);
  END resultado;

  FUNCTION lineas RETURN PLS_INTEGER IS
    v PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO v FROM reserva_habitacion WHERE id_habitacion = v_hab;
    RETURN v;
  END lineas;

  FUNCTION cabecera (p_in DATE, p_out DATE) RETURN reserva.id_reserva%TYPE IS
    v_id reserva.id_reserva%TYPE;
  BEGIN
    INSERT INTO reserva (id_cliente, id_alojamiento, fecha_reserva,
                         fecha_checkin, fecha_checkout, estado)
    VALUES (v_cli, v_aloj, SYSDATE, p_in, p_out, 'PENDIENTE')
    RETURNING id_reserva INTO v_id;
    RETURN v_id;
  END cabecera;

BEGIN
  IF TRUNC(SYSDATE) > c_in THEN
    DBMS_OUTPUT.PUT_LINE('Las fechas de prueba ya pasaron: cambie c_in y c_out.');
    RETURN;
  END IF;

  SELECT MIN(id_cliente) INTO v_cli FROM cliente;

  -- Habitación libre desde c_in hasta c_out + 10
  SELECT MIN(h.id_habitacion)
  INTO   v_hab
  FROM   habitacion h
  WHERE  NOT EXISTS (SELECT 1
                     FROM   reserva_habitacion rh
                     JOIN   reserva r ON r.id_reserva = rh.id_reserva
                     WHERE  rh.id_habitacion = h.id_habitacion
                     AND    r.estado <> 'CANCELADA'
                     AND    rh.fecha_checkin < c_out + 10
                     AND    c_in < rh.fecha_checkout);

  SELECT id_alojamiento INTO v_aloj FROM habitacion WHERE id_habitacion = v_hab;

  DBMS_OUTPUT.PUT_LINE('3.1 TRG_RESHAB_NO_SOLAPE  (habitación ' || v_hab || ')');
  DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');

  -- Reserva A, ocupa la habitación del c_in al c_out
  pkg_turismouq.sp_crear_reserva(v_cli, v_hab, c_in, c_out, 1, v_id_a);
  DBMS_OUTPUT.PUT_LINE('      Reserva A = ' || v_id_a || ' del ' ||
                       TO_CHAR(c_in, 'DD/MM') || ' al ' || TO_CHAR(c_out, 'DD/MM'));

  -- Cabeceras sin líneas para las pruebas
  v_id_b := cabecera(c_in, c_out + 5);
  v_id_c := cabecera(c_in, c_out + 9);
  v_id_d := cabecera(c_in, c_out + 9);

  -- a) INSERT que se cruza con A
  v_antes := lineas;
  BEGIN
    INSERT INTO reserva_habitacion (id_reserva, id_habitacion, fecha_checkin, fecha_checkout, num_huespedes)
    VALUES (v_id_b, v_hab, c_in + 2, c_out + 2, 1);
    resultado(FALSE, 'a) INSERT que se cruza', 'no lanzó error');
  EXCEPTION
    WHEN OTHERS THEN
      v_cod := SQLCODE; v_msg := SQLERRM;
      resultado(v_cod = -20020 AND lineas = v_antes, 'a) INSERT que se cruza', v_msg);
  END;

  -- b) INSERT que llega el día de salida de A (rango semiabierto)
  BEGIN
    INSERT INTO reserva_habitacion (id_reserva, id_habitacion, fecha_checkin, fecha_checkout, num_huespedes)
    VALUES (v_id_b, v_hab, c_out, c_out + 2, 1)
    RETURNING id_reserva_hab INTO v_linea;
    resultado(TRUE, 'b) INSERT el día de salida', 'línea ' || v_linea || ' aceptada');
  EXCEPTION
    WHEN OTHERS THEN
      resultado(FALSE, 'b) INSERT el día de salida', SQLERRM);
  END;

  -- c) UPDATE que adelanta un día la línea de b) y la cruza con A
  BEGIN
    UPDATE reserva_habitacion
    SET    fecha_checkin = c_out - 1
    WHERE  id_reserva_hab = v_linea;
    resultado(FALSE, 'c) UPDATE que se cruza', 'no lanzó error');
  EXCEPTION
    WHEN OTHERS THEN
      v_cod := SQLCODE; v_msg := SQLERRM;
      SELECT COUNT(*) INTO v_despues FROM reserva_habitacion
      WHERE  id_reserva_hab = v_linea AND fecha_checkin = c_out;
      resultado(v_cod = -20020 AND v_despues = 1, 'c) UPDATE que se cruza', v_msg);
  END;

  -- d) Dos líneas nuevas que se cruzan entre sí en la misma sentencia
  v_antes := lineas;
  BEGIN
    INSERT INTO reserva_habitacion (id_reserva, id_habitacion, fecha_checkin, fecha_checkout, num_huespedes)
    SELECT v_id_c, v_hab, c_out + 5, c_out + 8, 1 FROM dual
    UNION ALL
    SELECT v_id_d, v_hab, c_out + 6, c_out + 9, 1 FROM dual;
    resultado(FALSE, 'd) INSERT de 2 filas cruzadas', 'no lanzó error');
  EXCEPTION
    WHEN OTHERS THEN
      v_cod := SQLCODE; v_msg := SQLERRM;
      resultado(v_cod = -20020 AND lineas = v_antes, 'd) INSERT de 2 filas cruzadas', v_msg);
  END;

  -- e) Una reserva cancelada libera la habitación
  UPDATE reserva SET estado = 'CANCELADA' WHERE id_reserva = v_id_a;
  BEGIN
    INSERT INTO reserva_habitacion (id_reserva, id_habitacion, fecha_checkin, fecha_checkout, num_huespedes)
    VALUES (v_id_c, v_hab, c_in, c_out, 1);
    resultado(TRUE, 'e) INSERT sobre una cancelada', 'aceptado');
  EXCEPTION
    WHEN OTHERS THEN
      resultado(FALSE, 'e) INSERT sobre una cancelada', SQLERRM);
  END;

  DBMS_OUTPUT.PUT_LINE('Resultado: ' || CASE v_fallas WHEN 0 THEN 'todas OK'
                                         ELSE v_fallas || ' falla(s)' END);
  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('ROLLBACK: datos de prueba deshechos.');
END;
/

/* ---------------------------------------------------------------------
   3.2 TRG_TARIFA_AUDITORIA
   Sobre las tarifas de una habitación:
     a) UPDATE que no cambia el valor     -> no se audita nada
     b) UPDATE de +5 % en una sentencia   -> una fila UPDATE por tarifa,
                                             todas con la misma marca
                                             de tiempo, anterior y nuevo
     c) DELETE de una tarifa sin uso      -> una fila DELETE
     d) INSERT de esa misma tarifa        -> una fila INSERT
   Después del bloque, la consulta muestra lo que quedó en la auditoría
   (para la captura) y al final un ROLLBACK deshace cambios y auditoría.
   --------------------------------------------------------------------- */
DECLARE
  v_hab     habitacion.id_habitacion%TYPE;
  v_max     auditoria_tarifa.id_auditoria%TYPE;
  v_filas   PLS_INTEGER;
  v_n       PLS_INTEGER;
  v_m       PLS_INTEGER;
  v_tarifa  tarifa%ROWTYPE;
  v_fallas  PLS_INTEGER := 0;

  PROCEDURE resultado (p_ok BOOLEAN, p_desc VARCHAR2, p_detalle VARCHAR2 DEFAULT NULL) IS
  BEGIN
    IF NOT p_ok THEN v_fallas := v_fallas + 1; END IF;
    DBMS_OUTPUT.PUT_LINE(CASE WHEN p_ok THEN 'OK    ' ELSE 'FALLA ' END ||
                         RPAD(p_desc, 40) || ' ' || p_detalle);
  END resultado;

  FUNCTION nuevas (p_operacion VARCHAR2) RETURN PLS_INTEGER IS
    v PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO v FROM auditoria_tarifa
    WHERE  id_auditoria > v_max AND operacion = p_operacion;
    RETURN v;
  END nuevas;

BEGIN
  SELECT MIN(id_habitacion) INTO v_hab FROM habitacion;
  SELECT NVL(MAX(id_auditoria), 0) INTO v_max FROM auditoria_tarifa;

  DBMS_OUTPUT.PUT_LINE('3.2 TRG_TARIFA_AUDITORIA  (habitación ' || v_hab || ')');
  DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');

  -- a) Sin cambio real
  UPDATE tarifa SET valor_noche = valor_noche WHERE id_habitacion = v_hab;
  v_filas := SQL%ROWCOUNT;
  resultado(nuevas('UPDATE') = 0, 'a) UPDATE sin cambio de valor',
            v_filas || ' filas tocadas, 0 auditadas esperadas');

  -- b) +5 % en una sola sentencia
  UPDATE tarifa SET valor_noche = ROUND(valor_noche * 1.05) WHERE id_habitacion = v_hab;
  v_filas := SQL%ROWCOUNT;
  v_n := nuevas('UPDATE');
  resultado(v_n = v_filas, 'b) UPDATE +5 %: una fila por tarifa',
            v_filas || ' actualizadas, ' || v_n || ' auditadas');

  SELECT COUNT(DISTINCT fecha_cambio), COUNT(DISTINCT usuario_bd) INTO v_n, v_m
  FROM   auditoria_tarifa WHERE id_auditoria > v_max;
  resultado(v_n = 1 AND v_m = 1, '   misma marca de tiempo y usuario',
            'usuario ' || USER);

  SELECT COUNT(*) INTO v_n
  FROM   auditoria_tarifa a
  JOIN   tarifa t ON t.id_tarifa = a.id_tarifa
  WHERE  a.id_auditoria > v_max
  AND   (a.valor_nuevo <> t.valor_noche
         OR a.valor_nuevo <> ROUND(a.valor_anterior * 1.05));
  resultado(v_n = 0, '   anterior y nuevo correctos');

  -- c) DELETE de una tarifa que ninguna reserva usa
  SELECT * INTO v_tarifa
  FROM   tarifa ta
  WHERE  ta.id_tarifa = (SELECT MIN(t2.id_tarifa)
                         FROM   tarifa t2
                         WHERE  NOT EXISTS (SELECT 1 FROM reserva_noche rn
                                            WHERE  rn.id_tarifa = t2.id_tarifa));
  DELETE FROM tarifa WHERE id_tarifa = v_tarifa.id_tarifa;
  resultado(nuevas('DELETE') = 1, 'c) DELETE de una tarifa', 'id_tarifa ' || v_tarifa.id_tarifa);

  -- d) INSERT de la misma combinación habitación-temporada
  INSERT INTO tarifa (id_habitacion, id_temporada, valor_noche)
  VALUES (v_tarifa.id_habitacion, v_tarifa.id_temporada, v_tarifa.valor_noche);
  resultado(nuevas('INSERT') = 1, 'd) INSERT de una tarifa');

  DBMS_OUTPUT.PUT_LINE('Resultado: ' || CASE v_fallas WHEN 0 THEN 'todas OK'
                                         ELSE v_fallas || ' falla(s)' END);
  -- Sin ROLLBACK aquí, para que la consulta siguiente muestre la auditoría.
END;
/

-- Evidencia para la captura: últimos registros de la auditoría
SELECT id_auditoria, id_tarifa, operacion, valor_anterior, valor_nuevo,
       usuario_bd, TO_CHAR(fecha_cambio, 'DD/MM/YYYY HH24:MI:SS.FF3') AS fecha_cambio
FROM   auditoria_tarifa
ORDER  BY id_auditoria DESC
FETCH  FIRST 15 ROWS ONLY;

-- Deshace los cambios de tarifas y, con ellos, su auditoría
ROLLBACK;


/* =====================================================================
   4. CURSOR DE LIQUIDACIÓN MENSUAL                        
   ===================================================================== */

/* ---------------------------------------------------------------------
   4.1 Liquidación de diciembre de 2025
   Se compara cada total del mes contra un cálculo directo sobre las
   tablas. Luego se liquida el mismo mes otra vez: debe quedar igual
   (MERGE re-ejecutable, sin violar el UNIQUE).
   --------------------------------------------------------------------- */
DECLARE
  c_anio    CONSTANT PLS_INTEGER := 2025;
  c_mes     CONSTANT PLS_INTEGER := 12;
  c_desde   CONSTANT DATE := DATE '2025-12-01';
  c_hasta   CONSTANT DATE := DATE '2026-01-01';
  v_filas   PLS_INTEGER;
  v_aloj    PLS_INTEGER;
  v_noches  NUMBER;  v_noches_d  NUMBER;
  v_est     NUMBER;  v_est_d     NUMBER;
  v_ser     NUMBER;  v_ser_d     NUMBER;
  v_ret     NUMBER;  v_ret_d     NUMBER;
  v_neto1   NUMBER;  v_neto2     NUMBER;
  v_filas2  PLS_INTEGER;
  v_fallas  PLS_INTEGER := 0;

  PROCEDURE resultado (p_ok BOOLEAN, p_desc VARCHAR2, p_detalle VARCHAR2 DEFAULT NULL) IS
  BEGIN
    IF NOT p_ok THEN v_fallas := v_fallas + 1; END IF;
    DBMS_OUTPUT.PUT_LINE(CASE WHEN p_ok THEN 'OK    ' ELSE 'FALLA ' END ||
                         RPAD(p_desc, 36) || ' ' || p_detalle);
  END resultado;

  PROCEDURE leer_liquidacion IS
  BEGIN
    SELECT COUNT(*), SUM(noches_vendidas), SUM(total_estadias),
           SUM(total_servicios), SUM(total_retenido), SUM(total_neto)
    INTO   v_filas, v_noches, v_est, v_ser, v_ret, v_neto1
    FROM   liquidacion_mensual
    WHERE  anio = c_anio AND mes = c_mes;
  END leer_liquidacion;
BEGIN
  DBMS_OUTPUT.PUT_LINE('4.1 sp_liquidacion_mensual(' || c_anio || ', ' || c_mes || ')');
  DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');

  pkg_turismouq.sp_liquidacion_mensual(c_anio, c_mes);
  leer_liquidacion;

  -- Cálculos directos, sin pasar por el procedimiento
  SELECT COUNT(*) INTO v_aloj FROM alojamiento;

  SELECT COUNT(*), NVL(SUM(rn.valor_noche), 0) INTO v_noches_d, v_est_d
  FROM   reserva_noche rn
  JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
  JOIN   reserva r             ON r.id_reserva      = rh.id_reserva
  WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
  AND    rn.fecha_noche >= c_desde AND rn.fecha_noche < c_hasta;

  SELECT NVL(SUM(rs.cantidad * rs.precio_unitario), 0) INTO v_ser_d
  FROM   reserva_servicio rs
  JOIN   reserva r ON r.id_reserva = rs.id_reserva
  WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
  AND    rs.fecha_servicio >= c_desde AND rs.fecha_servicio < c_hasta;

  -- Retenido: cancelaciones con check-in en el mes, pagado - reembolso > 0
  SELECT NVL(SUM(pg.pagado - ca.monto_reembolso), 0) INTO v_ret_d
  FROM   cancelacion ca
  JOIN   reserva r ON r.id_reserva = ca.id_reserva
  JOIN  (SELECT id_reserva, SUM(monto) AS pagado
         FROM   pago
         WHERE  estado IN ('EXITOSO', 'REEMBOLSADO')
         GROUP  BY id_reserva) pg ON pg.id_reserva = ca.id_reserva
  WHERE  r.fecha_checkin >= c_desde AND r.fecha_checkin < c_hasta
  AND    pg.pagado - ca.monto_reembolso > 0;

  resultado(v_filas = v_aloj,     'una fila por alojamiento', v_filas || ' de ' || v_aloj);
  resultado(v_noches = v_noches_d, 'noches vendidas',  TO_CHAR(v_noches));
  resultado(v_est = v_est_d,       'total estadías',   TO_CHAR(v_est, 'FM999G999G999G990'));
  resultado(v_ser = v_ser_d,       'total servicios',  TO_CHAR(v_ser, 'FM999G999G999G990'));
  resultado(v_ret = v_ret_d,       'total retenido',   TO_CHAR(v_ret, 'FM999G999G999G990'));
  resultado(v_neto1 = v_est + v_ser + v_ret, 'neto = estadías + servicios + retenido',
            TO_CHAR(v_neto1, 'FM999G999G999G990'));

  -- Segunda ejecución del mismo mes
  v_neto2 := v_neto1;
  v_filas2 := v_filas;
  pkg_turismouq.sp_liquidacion_mensual(c_anio, c_mes);
  leer_liquidacion;
  resultado(v_filas = v_filas2 AND v_neto1 = v_neto2,
            'segunda ejecución: mismo resultado', v_filas || ' filas, sin duplicados');

  DBMS_OUTPUT.PUT_LINE('Resultado: ' || CASE v_fallas WHEN 0 THEN 'todas OK'
                                         ELSE v_fallas || ' falla(s)' END);
  COMMIT;
END;
/

-- Evidencia: los 10 alojamientos con mayor neto en diciembre de 2025
SELECT l.id_alojamiento, a.nombre_comercial, l.noches_vendidas,
       l.total_estadias, l.total_servicios, l.total_retenido, l.total_neto,
       TO_CHAR(l.fecha_generacion, 'DD/MM/YYYY HH24:MI') AS generada
FROM   liquidacion_mensual l
JOIN   alojamiento a ON a.id_alojamiento = l.id_alojamiento
WHERE  l.anio = 2025 AND l.mes = 12
ORDER  BY l.total_neto DESC
FETCH  FIRST 10 ROWS ONLY;

/* ---------------------------------------------------------------------
   4.2 Periodos inválidos: deben lanzar -20030
   --------------------------------------------------------------------- */
DECLARE
  v_fallas PLS_INTEGER := 0;

  PROCEDURE probar_error (p_desc VARCHAR2, p_anio NUMBER, p_mes NUMBER) IS
  BEGIN
    pkg_turismouq.sp_liquidacion_mensual(p_anio, p_mes);
    v_fallas := v_fallas + 1;
    DBMS_OUTPUT.PUT_LINE('FALLA ' || RPAD(p_desc, 24) || ' no lanzó error');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20030 THEN
        DBMS_OUTPUT.PUT_LINE('OK    ' || RPAD(p_desc, 24) || ' ' || SQLERRM);
      ELSE
        v_fallas := v_fallas + 1;
        DBMS_OUTPUT.PUT_LINE('FALLA ' || RPAD(p_desc, 24) || ' ' || SQLERRM);
      END IF;
  END probar_error;
BEGIN
  DBMS_OUTPUT.PUT_LINE('4.2 Periodos inválidos');
  DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');
  probar_error('mes 13',      2025, 13);
  probar_error('mes 0',       2025, 0);
  probar_error('año 2023',    2023, 5);
  probar_error('mes nulo',    2025, NULL);
  DBMS_OUTPUT.PUT_LINE('Resultado: ' || CASE v_fallas WHEN 0 THEN 'todas OK'
                                         ELSE v_fallas || ' falla(s)' END);
END;
/

/* ---------------------------------------------------------------------
   4.3 Proceso masivo: todos los meses de enero de 2024 a septiembre
   de 2026 (fecha de corte de los datos). Cada mes imprime su resumen.
   Al final, LIQUIDACION_MENSUAL debe tener alojamientos x meses filas.
   --------------------------------------------------------------------- */
DECLARE
  v_mes    DATE := DATE '2024-01-01';
  v_meses  PLS_INTEGER := 0;
  v_filas  PLS_INTEGER;
  v_aloj   PLS_INTEGER;
  v_inicio PLS_INTEGER := DBMS_UTILITY.GET_TIME;
BEGIN
  DBMS_OUTPUT.PUT_LINE('4.3 Liquidación masiva 01/2024 - 09/2026');
  DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');

  WHILE v_mes <= DATE '2026-09-01' LOOP
    pkg_turismouq.sp_liquidacion_mensual(EXTRACT(YEAR FROM v_mes), EXTRACT(MONTH FROM v_mes));
    v_meses := v_meses + 1;
    v_mes   := ADD_MONTHS(v_mes, 1);
  END LOOP;
  COMMIT;

  SELECT COUNT(*) INTO v_aloj FROM alojamiento;
  SELECT COUNT(*) INTO v_filas FROM liquidacion_mensual
  WHERE  anio * 100 + mes BETWEEN 202401 AND 202609;

  DBMS_OUTPUT.PUT_LINE(CASE WHEN v_filas = v_aloj * v_meses THEN 'OK    ' ELSE 'FALLA ' END ||
                       v_meses || ' meses x ' || v_aloj || ' alojamientos = ' || v_filas ||
                       ' filas en ' || ROUND((DBMS_UTILITY.GET_TIME - v_inicio) / 100, 1) || ' s');
END;
/

-- Evidencia: neto liquidado por año
SELECT anio, COUNT(*) AS liquidaciones, SUM(noches_vendidas) AS noches,
       SUM(total_neto) AS neto
FROM   liquidacion_mensual
GROUP  BY anio
ORDER  BY anio;

/* ---------------------------------------------------------------------
   4.4 Liquidación vs. V_INGRESO_RECONOCIDO (Entrega 1)
   Evidencia de la decisión 2: la liquidación usa la misma definición
   de ingreso que la vista base de las consultas (RN11). Para cada
   alojamiento y mes de 01/2024 a 09/2026 se compara cada concepto:
     total_estadias  vs. ESTADIA   (mes de la noche)
     total_servicios vs. SERVICIO  (mes del servicio)
     total_retenido  vs. RETENCION (mes del check-in)
     total_neto      vs. suma de los tres
   Todas las columnas de diferencias deben dar 0, y también la última:
   ningún ingreso de la vista puede quedar fuera de la liquidación.
   Requiere haber ejecutado 4_Consultas.sql (crea la vista) y la 4.3.
   --------------------------------------------------------------------- */
WITH liq AS (
  SELECT id_alojamiento, anio, mes,
         total_estadias, total_servicios, total_retenido, total_neto
  FROM   liquidacion_mensual
  WHERE  anio * 100 + mes BETWEEN 202401 AND 202609
),
vista AS (
  SELECT id_alojamiento,
         EXTRACT(YEAR  FROM fecha) AS anio,
         EXTRACT(MONTH FROM fecha) AS mes,
         SUM(CASE concepto WHEN 'ESTADIA'   THEN monto ELSE 0 END) AS estadias,
         SUM(CASE concepto WHEN 'SERVICIO'  THEN monto ELSE 0 END) AS servicios,
         SUM(CASE concepto WHEN 'RETENCION' THEN monto ELSE 0 END) AS retenido,
         SUM(monto)                                                AS total
  FROM   v_ingreso_reconocido
  WHERE  fecha >= DATE '2024-01-01' AND fecha < DATE '2026-10-01'
  GROUP  BY id_alojamiento, EXTRACT(YEAR FROM fecha), EXTRACT(MONTH FROM fecha)
)
SELECT COUNT(*)                                                                   AS liquidaciones,
       SUM(CASE WHEN l.total_estadias  <> NVL(v.estadias, 0)  THEN 1 ELSE 0 END) AS dif_estadias,
       SUM(CASE WHEN l.total_servicios <> NVL(v.servicios, 0) THEN 1 ELSE 0 END) AS dif_servicios,
       SUM(CASE WHEN l.total_retenido  <> NVL(v.retenido, 0)  THEN 1 ELSE 0 END) AS dif_retenido,
       SUM(CASE WHEN l.total_neto      <> NVL(v.total, 0)     THEN 1 ELSE 0 END) AS dif_neto,
       (SELECT COUNT(*)
        FROM   vista v2
        WHERE  NOT EXISTS (SELECT 1 FROM liq l2
                           WHERE  l2.id_alojamiento = v2.id_alojamiento
                           AND    l2.anio = v2.anio AND l2.mes = v2.mes))         AS meses_sin_liquidar
FROM   liq l
LEFT JOIN vista v
       ON  v.id_alojamiento = l.id_alojamiento
       AND v.anio = l.anio AND v.mes = l.mes;

-- Evidencia: lo retenido por año, desde la liquidación y desde la vista
SELECT l.anio,
       SUM(l.total_retenido)                                     AS retenido_liquidacion,
       (SELECT NVL(SUM(monto), 0)
        FROM   v_ingreso_reconocido
        WHERE  concepto = 'RETENCION'
        AND    EXTRACT(YEAR FROM fecha) = l.anio
        AND    fecha < DATE '2026-10-01')                        AS retenido_vista
FROM   liquidacion_mensual l
WHERE  l.anio * 100 + l.mes BETWEEN 202401 AND 202609
GROUP  BY l.anio
ORDER  BY l.anio;


/* =====================================================================
   5. TABLESPACE Y VISTA MATERIALIZADA                     
   ===================================================================== */

/* ---------------------------------------------------------------------
   5.1 Tablespace: existe, tiene cuota y guarda la tabla del histórico
   y su índice (los dos segmentos deben salir en TS_HISTORICO_RESERVAS).
   --------------------------------------------------------------------- */
SELECT tablespace_name, status, contents, extent_management, segment_space_management
FROM   user_tablespaces
WHERE  tablespace_name = 'TS_HISTORICO_RESERVAS';

SELECT segment_name, segment_type, tablespace_name,
       ROUND(bytes / 1024 / 1024, 2) AS mb
FROM   user_segments
WHERE  segment_name IN ('RESERVA', 'RESERVA_HISTORICO', 'PK_RESERVA_HISTORICO')
ORDER  BY tablespace_name, segment_name;

/* ---------------------------------------------------------------------
   5.2 Histórico: cada reserva cerrada antes del corte está archivada
   y sus valores coinciden con las tablas operativas.
   --------------------------------------------------------------------- */
SELECT (SELECT COUNT(*) FROM reserva
        WHERE  estado IN ('COMPLETADA', 'CANCELADA')
        AND    fecha_checkout < DATE '2026-01-01')               AS reservas_cerradas,
       (SELECT COUNT(*) FROM reserva_historico)                  AS archivadas,
       (SELECT COUNT(*)
        FROM   reserva_historico h
        WHERE  h.valor_estadia <> (SELECT NVL(SUM(rn.valor_noche), 0)
                                   FROM   reserva_noche rn
                                   JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
                                   WHERE  rh.id_reserva = h.id_reserva)) AS diferencias_valor
FROM   dual;

/* ---------------------------------------------------------------------
   5.3 Vista materializada vs. consulta 1 de la Entrega 1
   Ocupación de 2025 por municipio y mes calculada de las dos formas.
   La columna diferencias debe dar 0.
   --------------------------------------------------------------------- */
WITH desde_mv AS (
  SELECT id_municipio, mes,
         ROUND(100 * SUM(noches_vendidas) / SUM(noches_disponibles), 1) AS ocupacion
  FROM   mv_ocupacion_mensual
  WHERE  anio = 2025
  GROUP  BY id_municipio, mes
),
directo AS (
  SELECT c.id_municipio, me.mes,
         ROUND(100 * NVL(n.noches, 0) / (c.habitaciones * me.dias), 1) AS ocupacion
  FROM  (SELECT a.id_municipio, COUNT(*) AS habitaciones
         FROM   habitacion h JOIN alojamiento a ON a.id_alojamiento = h.id_alojamiento
         GROUP  BY a.id_municipio) c
  CROSS JOIN (SELECT LEVEL AS mes,
                     EXTRACT(DAY FROM LAST_DAY(ADD_MONTHS(DATE '2025-01-01', LEVEL - 1))) AS dias
              FROM dual CONNECT BY LEVEL <= 12) me
  LEFT JOIN (SELECT a.id_municipio, EXTRACT(MONTH FROM rn.fecha_noche) AS mes, COUNT(*) AS noches
             FROM   reserva_noche rn
             JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
             JOIN   reserva r             ON r.id_reserva      = rh.id_reserva
             JOIN   alojamiento a         ON a.id_alojamiento  = r.id_alojamiento
             WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
             AND    rn.fecha_noche >= DATE '2025-01-01' AND rn.fecha_noche < DATE '2026-01-01'
             GROUP  BY a.id_municipio, EXTRACT(MONTH FROM rn.fecha_noche)) n
         ON n.id_municipio = c.id_municipio AND n.mes = me.mes
)
SELECT COUNT(*)                                                    AS celdas,
       SUM(CASE WHEN m.ocupacion = d.ocupacion THEN 0 ELSE 1 END)  AS diferencias
FROM   desde_mv m
JOIN   directo  d ON d.id_municipio = m.id_municipio AND d.mes = m.mes;

-- Evidencia: ocupación de 2025 por municipio desde la vista
SELECT municipio,
       SUM(noches_vendidas)                                           AS noches_vendidas,
       SUM(noches_disponibles)                                        AS noches_disponibles,
       ROUND(100 * SUM(noches_vendidas) / SUM(noches_disponibles), 1) AS ocupacion_pct
FROM   mv_ocupacion_mensual
WHERE  anio = 2025
GROUP  BY municipio
ORDER  BY ocupacion_pct DESC;

/* ---------------------------------------------------------------------
   5.4 Política de refresco en acción
     1. Se crea y confirma una reserva de 5 noches en diciembre de 2026.
     2. La vista NO cambia: es ON DEMAND, guarda la foto del último
        refresco.
     3. Se refresca a mano y la vista suma las 5 noches.
     4. Se borra la reserva de prueba y se refresca de nuevo.
   OJO: DBMS_MVIEW.REFRESH hace COMMIT implícito, por eso la reserva de
   prueba se borra explícitamente en el paso 4 (un ROLLBACK ya no la
   desharía).
   --------------------------------------------------------------------- */
DECLARE
  c_in     CONSTANT DATE := DATE '2026-12-08';
  c_out    CONSTANT DATE := DATE '2026-12-13';
  v_hab    habitacion.id_habitacion%TYPE;
  v_aloj   habitacion.id_alojamiento%TYPE;
  v_cli    cliente.id_cliente%TYPE;
  v_id     reserva.id_reserva%TYPE;
  v_antes  NUMBER;
  v_medio  NUMBER;
  v_despues NUMBER;
  v_final  NUMBER;

  FUNCTION noches_mv RETURN NUMBER IS
    v NUMBER;
  BEGIN
    SELECT NVL(SUM(noches_vendidas), 0) INTO v
    FROM   mv_ocupacion_mensual
    WHERE  id_alojamiento = v_aloj AND mes_inicio = DATE '2026-12-01';
    RETURN v;
  END noches_mv;
BEGIN
  IF TRUNC(SYSDATE) > c_in THEN
    DBMS_OUTPUT.PUT_LINE('Las fechas de prueba ya pasaron: cambie c_in y c_out.');
    RETURN;
  END IF;

  SELECT MIN(id_cliente) INTO v_cli FROM cliente;
  SELECT MIN(h.id_habitacion) INTO v_hab
  FROM   habitacion h
  WHERE  NOT EXISTS (SELECT 1
                     FROM   reserva_habitacion rh
                     JOIN   reserva r ON r.id_reserva = rh.id_reserva
                     WHERE  rh.id_habitacion = h.id_habitacion
                     AND    r.estado <> 'CANCELADA'
                     AND    rh.fecha_checkin < c_out AND c_in < rh.fecha_checkout);
  SELECT id_alojamiento INTO v_aloj FROM habitacion WHERE id_habitacion = v_hab;

  DBMS_OUTPUT.PUT_LINE('5.4 Refresco de MV_OCUPACION_MENSUAL (alojamiento ' || v_aloj ||
                       ', diciembre 2026)');
  DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');

  v_antes := noches_mv;
  DBMS_OUTPUT.PUT_LINE('      antes de la reserva       : ' || v_antes || ' noches');

  pkg_turismouq.sp_crear_reserva(v_cli, v_hab, c_in, c_out, 1, v_id);
  UPDATE reserva SET estado = 'CONFIRMADA' WHERE id_reserva = v_id;
  COMMIT;

  v_medio := noches_mv;
  DBMS_OUTPUT.PUT_LINE(CASE WHEN v_medio = v_antes THEN 'OK    ' ELSE 'FALLA ' END ||
                       'reserva confirmada, sin refresco: ' || v_medio ||
                       ' noches (la vista no cambia)');

  DBMS_MVIEW.REFRESH('MV_OCUPACION_MENSUAL', 'C');
  v_despues := noches_mv;
  DBMS_OUTPUT.PUT_LINE(CASE WHEN v_despues = v_antes + 5 THEN 'OK    ' ELSE 'FALLA ' END ||
                       'después del refresco         : ' || v_despues || ' noches (+5)');

  -- Limpieza: RESERVA_HABITACION y RESERVA_NOCHE se borran en cascada
  DELETE FROM reserva WHERE id_reserva = v_id;
  COMMIT;
  DBMS_MVIEW.REFRESH('MV_OCUPACION_MENSUAL', 'C');
  v_final := noches_mv;
  DBMS_OUTPUT.PUT_LINE(CASE WHEN v_final = v_antes THEN 'OK    ' ELSE 'FALLA ' END ||
                       'reserva de prueba borrada     : ' || v_final || ' noches');
END;
/

-- Evidencia: metadatos de la vista y del job que la refresca cada noche
SELECT mview_name, refresh_mode, refresh_method,
       TO_CHAR(last_refresh_date, 'DD/MM/YYYY HH24:MI:SS') AS ultimo_refresco
FROM   user_mviews
WHERE  mview_name = 'MV_OCUPACION_MENSUAL';

SELECT job_name, enabled, state, repeat_interval,
       TO_CHAR(next_run_date, 'DD/MM/YYYY HH24:MI') AS proxima_ejecucion
FROM   user_scheduler_jobs
WHERE  job_name = 'JOB_REFRESCO_OCUPACION';

/* Fin del script de pruebas */
