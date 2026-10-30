/* =====================================================================
   PROYECTO INTEGRADOR - BASES DE DATOS II
   TurismoUQ: plataforma de reservas de alojamientos en el Quindío
   ---------------------------------------------------------------------
   Archivo   : 5_paquete.sql
   Entrega   : 2 - Capa PL/SQL (función, procedimiento, cursor y paquete)
   Requiere  : 2_DDL.sql y 3_cargue_datos.sql ejecutados antes
   Motor     : Oracle Database 21c XE
   ---------------------------------------------------------------------
   ===================================================================== */

SET SERVEROUTPUT ON SIZE UNLIMITED


/* =====================================================================
   1. ESPECIFICACIÓN
   ---------------------------------------------------------------------
   Es la parte pública del paquete: lo que otros objetos (disparadores,
   pruebas, Entrega 3) pueden usar. 
     -20001 a -20009  sp_crear_reserva      
     -20010 a -20019  fn_valor_estadia       
     -20020 a -20029  disparadores           
     -20030 a -20039  sp_liquidacion_mensual 
   ===================================================================== */

CREATE OR REPLACE PACKAGE pkg_turismouq AS

  -- -------------------------------------------------------------------
  -- Códigos de error. Se usan como RAISE_APPLICATION_ERROR(c_err_..., ...)
  -- -------------------------------------------------------------------
  c_err_fechas_reserva   CONSTANT PLS_INTEGER := -20001;  -- checkout <= checkin
  c_err_capacidad        CONSTANT PLS_INTEGER := -20002;  -- huéspedes > capacidad_max
  c_err_no_disponible    CONSTANT PLS_INTEGER := -20003;  -- habitación ocupada en el rango
  c_err_cliente          CONSTANT PLS_INTEGER := -20004;  -- el cliente no existe

  c_err_param_estadia    CONSTANT PLS_INTEGER := -20010;  -- parámetros nulos o fechas inválidas
  c_err_hab_inexistente  CONSTANT PLS_INTEGER := -20011;  -- la habitación no existe
  c_err_sin_tarifa       CONSTANT PLS_INTEGER := -20012;  -- alguna noche sin temporada o sin tarifa

  c_err_solape           CONSTANT PLS_INTEGER := -20020;  -- disparador de fila: solape
  c_err_periodo          CONSTANT PLS_INTEGER := -20030;  -- liquidación: año o mes inválido

  -- -------------------------------------------------------------------
  -- Excepciones con nombre. Permiten atrapar un error concreto con
  --   EXCEPTION WHEN pkg_turismouq.e_sin_tarifa THEN ...
  -- en lugar de comparar SQLCODE. PRAGMA EXCEPTION_INIT exige el número
  -- literal, por eso se repite el código de la constante.
  -- -------------------------------------------------------------------
  e_fechas_reserva   EXCEPTION;  PRAGMA EXCEPTION_INIT(e_fechas_reserva,   -20001);
  e_capacidad        EXCEPTION;  PRAGMA EXCEPTION_INIT(e_capacidad,        -20002);
  e_no_disponible    EXCEPTION;  PRAGMA EXCEPTION_INIT(e_no_disponible,    -20003);
  e_cliente          EXCEPTION;  PRAGMA EXCEPTION_INIT(e_cliente,          -20004);
  e_param_estadia    EXCEPTION;  PRAGMA EXCEPTION_INIT(e_param_estadia,    -20010);
  e_hab_inexistente  EXCEPTION;  PRAGMA EXCEPTION_INIT(e_hab_inexistente,  -20011);
  e_sin_tarifa       EXCEPTION;  PRAGMA EXCEPTION_INIT(e_sin_tarifa,       -20012);
  e_solape           EXCEPTION;  PRAGMA EXCEPTION_INIT(e_solape,           -20020);
  e_periodo          EXCEPTION;  PRAGMA EXCEPTION_INIT(e_periodo,          -20030);

  -- -------------------------------------------------------------------
  -- fn_valor_estadia
  -- Valor total de alojarse en una habitación entre p_fecha_in (noche de
  -- llegada) y p_fecha_out (día de salida, que NO se cobra). Cada noche
  -- se cobra con la tarifa de la temporada que la contiene, así que una
  -- estadía que atraviesa varias temporadas suma un tramo por cada una.
  -- No hace DML: se puede llamar desde SQL (SELECT ... FROM dual).
  -- -------------------------------------------------------------------
  FUNCTION fn_valor_estadia (
    p_id_habitacion IN habitacion.id_habitacion%TYPE,
    p_fecha_in      IN DATE,
    p_fecha_out     IN DATE
  ) RETURN NUMBER;

  -- -------------------------------------------------------------------
  -- fn_tarifa_noche
  -- Fila de TARIFA que aplica a una habitación en una fecha concreta.
  -- La usa sp_crear_reserva para llenar RESERVA_NOCHE (id_tarifa y
  -- valor congelado de cada noche). Devuelve un registro, por lo que
  -- solo se puede usar desde PL/SQL.
  -- -------------------------------------------------------------------
  FUNCTION fn_tarifa_noche (
    p_id_habitacion IN habitacion.id_habitacion%TYPE,
    p_fecha         IN DATE
  ) RETURN tarifa%ROWTYPE;

  -- -------------------------------------------------------------------
  -- sp_crear_reserva  
  -- Crea una reserva PENDIENTE de una habitación: RESERVA +
  -- RESERVA_HABITACION + una fila de RESERVA_NOCHE por noche. Valida
  -- fechas, cliente, habitación, capacidad y disponibilidad. Devuelve
  -- el id de la reserva creada.
  -- NO hace COMMIT: quien la llama decide cuándo confirmar la
  -- transacción (la Entrega 3 la combina con el pago en una sola
  -- transacción atómica). Si falla, deshace todo lo que alcanzó a
  -- insertar y propaga el error.
  -- -------------------------------------------------------------------
  PROCEDURE sp_crear_reserva (
    p_id_cliente    IN  cliente.id_cliente%TYPE,
    p_id_habitacion IN  habitacion.id_habitacion%TYPE,
    p_fecha_in      IN  DATE,
    p_fecha_out     IN  DATE,
    p_num_huespedes IN  reserva_habitacion.num_huespedes%TYPE,
    p_id_reserva    OUT reserva.id_reserva%TYPE
  );

  -- -------------------------------------------------------------------
  -- sp_liquidacion_mensual  
  -- Recorre los alojamientos con un cursor explícito con parámetros y
  -- registra (MERGE) la liquidación de un mes en LIQUIDACION_MENSUAL.
  -- -------------------------------------------------------------------
  PROCEDURE sp_liquidacion_mensual (
    p_anio IN liquidacion_mensual.anio%TYPE,
    p_mes  IN liquidacion_mensual.mes%TYPE
  );

END pkg_turismouq;
/


/* =====================================================================
   2. CUERPO
   ===================================================================== */

CREATE OR REPLACE PACKAGE BODY pkg_turismouq AS

  /* -------------------------------------------------------------------
     2.1 fn_valor_estadia                                  
     -------------------------------------------------------------------
     ------------------------------------------------------------------- */
  FUNCTION fn_valor_estadia (
    p_id_habitacion IN habitacion.id_habitacion%TYPE,
    p_fecha_in      IN DATE,
    p_fecha_out     IN DATE
  ) RETURN NUMBER
  IS
    -- Se quita la hora para trabajar con días completos, como el resto
    -- del modelo (las fechas de RESERVA y TEMPORADA no llevan hora).
    v_in               DATE := TRUNC(p_fecha_in);
    v_out              DATE := TRUNC(p_fecha_out);
    v_existe           PLS_INTEGER;
    v_noches_esperadas PLS_INTEGER;
    v_noches_cubiertas PLS_INTEGER;
    v_valor            NUMBER(14,2);
  BEGIN
    -- 1. Validación de parámetros
    IF p_id_habitacion IS NULL OR v_in IS NULL OR v_out IS NULL THEN
      RAISE_APPLICATION_ERROR(c_err_param_estadia,
        'fn_valor_estadia: la habitación y las dos fechas son obligatorias.');
    END IF;

    IF v_out <= v_in THEN
      RAISE_APPLICATION_ERROR(c_err_param_estadia,
        'fn_valor_estadia: el checkout (' || TO_CHAR(v_out, 'DD/MM/YYYY') ||
        ') debe ser posterior al checkin (' || TO_CHAR(v_in, 'DD/MM/YYYY') || ').');
    END IF;

    SELECT COUNT(*)
    INTO   v_existe
    FROM   habitacion
    WHERE  id_habitacion = p_id_habitacion;

    IF v_existe = 0 THEN
      RAISE_APPLICATION_ERROR(c_err_hab_inexistente,
        'fn_valor_estadia: la habitación ' || p_id_habitacion || ' no existe.');
    END IF;

    v_noches_esperadas := v_out - v_in;

    -- 2. Un tramo por cada temporada que se cruza con la estadía.
    --    Condición de cruce entre [v_in, v_out) y [fecha_inicio, fecha_fin]:
    --    la temporada empieza antes de la salida y termina el día de
    --    llegada o después.
    SELECT NVL(SUM(ta.valor_noche
                   * (LEAST(t.fecha_fin + 1, v_out) - GREATEST(t.fecha_inicio, v_in))), 0),
           NVL(SUM(  LEAST(t.fecha_fin + 1, v_out) - GREATEST(t.fecha_inicio, v_in)), 0)
    INTO   v_valor,
           v_noches_cubiertas
    FROM   temporada t
    JOIN   tarifa    ta
           ON  ta.id_temporada  = t.id_temporada
           AND ta.id_habitacion = p_id_habitacion
    WHERE  t.fecha_inicio <  v_out
    AND    t.fecha_fin    >= v_in;

    -- 3. Control de cobertura: todas las noches deben tener tarifa.
    IF v_noches_cubiertas <> v_noches_esperadas THEN
      RAISE_APPLICATION_ERROR(c_err_sin_tarifa,
        'fn_valor_estadia: la habitación ' || p_id_habitacion || ' tiene ' ||
        v_noches_cubiertas || ' de ' || v_noches_esperadas ||
        ' noches con tarifa entre el ' || TO_CHAR(v_in, 'DD/MM/YYYY') ||
        ' y el ' || TO_CHAR(v_out, 'DD/MM/YYYY') ||
        '. Revise que TEMPORADA cubra esas fechas y que TARIFA tenga el precio.');
    END IF;

    RETURN v_valor;
  END fn_valor_estadia;


  /* -------------------------------------------------------------------
     2.2 fn_tarifa_noche                                   
     -------------------------------------------------------------------
     Busca la temporada que contiene la fecha y la tarifa de la
     habitación en esa temporada. Como las temporadas no tienen huecos
     ni solapes (RN7), debe existir exactamente una fila.
     ------------------------------------------------------------------- */
  FUNCTION fn_tarifa_noche (
    p_id_habitacion IN habitacion.id_habitacion%TYPE,
    p_fecha         IN DATE
  ) RETURN tarifa%ROWTYPE
  IS
    v_tarifa tarifa%ROWTYPE;
  BEGIN
    SELECT ta.*
    INTO   v_tarifa
    FROM   tarifa    ta
    JOIN   temporada t ON t.id_temporada = ta.id_temporada
    WHERE  ta.id_habitacion = p_id_habitacion
    AND    TRUNC(p_fecha) BETWEEN t.fecha_inicio AND t.fecha_fin;

    RETURN v_tarifa;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(c_err_sin_tarifa,
        'fn_tarifa_noche: no hay tarifa para la habitación ' || p_id_habitacion ||
        ' en la noche del ' || TO_CHAR(p_fecha, 'DD/MM/YYYY') || '.');
    WHEN TOO_MANY_ROWS THEN
      RAISE_APPLICATION_ERROR(c_err_sin_tarifa,
        'fn_tarifa_noche: hay temporadas solapadas el ' ||
        TO_CHAR(p_fecha, 'DD/MM/YYYY') || '; revise la tabla TEMPORADA.');
  END fn_tarifa_noche;


  /* -------------------------------------------------------------------
     2.3 sp_crear_reserva                                 
     -------------------------------------------------------------------
     ORDEN DE LAS VALIDACIONES
     Primero lo que no requiere leer tablas (fechas), luego la
     existencia del cliente y de la habitación, después la capacidad
     y por último la disponibilidad, que es la consulta más costosa.
     Todas se hacen ANTES de insertar, para lanzar el error propio con
     un mensaje claro en vez del error genérico de un CHECK (ORA-02290).

       Regla                                  Código   RN
       checkout posterior al checkin           -20001   RN5
       checkin no anterior a hoy               -20001   CHECK ck_reserva_anticipacion
       el cliente existe                       -20004
       la habitación existe                    -20011
       1 <= huéspedes <= capacidad_max         -20002   RN6
       habitación libre en el rango            -20003   RN3
       todas las noches tienen tarifa          -20012   RN7 (vía fn_valor_estadia)

     DISPONIBILIDAD (RN3)
     Dos estadías se cruzan si cada una empieza antes de que termine la
     otra. Con rangos semiabiertos [checkin, checkout):
         existente.checkin < nuevo.checkout
     AND nuevo.checkin     < existente.checkout
     Así, el día de salida de un huésped puede ser el de llegada de
     otro. Se comparan las LÍNEAS (RESERVA_HABITACION), que es donde
     están la habitación y las fechas reales, contra reservas no
     canceladas (ver la justificación en 6_disparadores.sql).

     ESTA VALIDACIÓN Y EL DISPARADOR
     El disparador TRG_RESHAB_NO_SOLAPE repite el control al insertar la
     línea. No es redundante: el procedimiento da el error amable
     (-20003) en el camino normal, y el disparador (-20020) protege la
     tabla de cualquier inserción o actualización que no pase por aquí.


     ------------------------------------------------------------------- */
  PROCEDURE sp_crear_reserva (
    p_id_cliente    IN  cliente.id_cliente%TYPE,
    p_id_habitacion IN  habitacion.id_habitacion%TYPE,
    p_fecha_in      IN  DATE,
    p_fecha_out     IN  DATE,
    p_num_huespedes IN  reserva_habitacion.num_huespedes%TYPE,
    p_id_reserva    OUT reserva.id_reserva%TYPE
  )
  IS
    v_in             DATE := TRUNC(p_fecha_in);
    v_out            DATE := TRUNC(p_fecha_out);
    v_existe         PLS_INTEGER;
    v_capacidad      habitacion.capacidad_max%TYPE;
    v_id_alojamiento habitacion.id_alojamiento%TYPE;
    v_conflicto      reserva.id_reserva%TYPE;
    v_valor          NUMBER;
    v_id_reserva_hab reserva_habitacion.id_reserva_hab%TYPE;
    v_tarifa         tarifa%ROWTYPE;
  BEGIN
    SAVEPOINT sp_crear_reserva_inicio;
    p_id_reserva := NULL;

    -- 1. Fechas
    IF v_in IS NULL OR v_out IS NULL THEN
      RAISE_APPLICATION_ERROR(c_err_fechas_reserva,
        'sp_crear_reserva: las fechas de checkin y checkout son obligatorias.');
    END IF;

    IF v_out <= v_in THEN
      RAISE_APPLICATION_ERROR(c_err_fechas_reserva,
        'sp_crear_reserva: el checkout (' || TO_CHAR(v_out, 'DD/MM/YYYY') ||
        ') debe ser posterior al checkin (' || TO_CHAR(v_in, 'DD/MM/YYYY') || ').');
    END IF;

    IF v_in < TRUNC(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(c_err_fechas_reserva,
        'sp_crear_reserva: el checkin (' || TO_CHAR(v_in, 'DD/MM/YYYY') ||
        ') no puede ser anterior a hoy.');
    END IF;

    -- 2. Cliente
    SELECT COUNT(*) INTO v_existe
    FROM   cliente
    WHERE  id_cliente = p_id_cliente;

    IF v_existe = 0 THEN
      RAISE_APPLICATION_ERROR(c_err_cliente,
        'sp_crear_reserva: el cliente ' || p_id_cliente || ' no existe.');
    END IF;

    -- 3. Habitación: capacidad y alojamiento al que pertenece (RN4)
    BEGIN
      SELECT capacidad_max, id_alojamiento
      INTO   v_capacidad, v_id_alojamiento
      FROM   habitacion
      WHERE  id_habitacion = p_id_habitacion;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(c_err_hab_inexistente,
          'sp_crear_reserva: la habitación ' || p_id_habitacion || ' no existe.');
    END;

    -- 4. Capacidad (RN6)
    IF p_num_huespedes IS NULL OR p_num_huespedes < 1 THEN
      RAISE_APPLICATION_ERROR(c_err_capacidad,
        'sp_crear_reserva: la reserva debe tener al menos un huésped.');
    END IF;

    IF p_num_huespedes > v_capacidad THEN
      RAISE_APPLICATION_ERROR(c_err_capacidad,
        'sp_crear_reserva: ' || p_num_huespedes || ' huéspedes superan la capacidad ' ||
        'máxima de la habitación ' || p_id_habitacion || ' (' || v_capacidad || ').');
    END IF;

    -- 5. Disponibilidad (RN3): primera reserva no cancelada que se cruza
    SELECT MIN(rh.id_reserva)
    INTO   v_conflicto
    FROM   reserva_habitacion rh
    JOIN   reserva            r ON r.id_reserva = rh.id_reserva
    WHERE  rh.id_habitacion  = p_id_habitacion
    AND    r.estado         <> 'CANCELADA'
    AND    rh.fecha_checkin  < v_out
    AND    v_in              < rh.fecha_checkout;

    IF v_conflicto IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(c_err_no_disponible,
        'sp_crear_reserva: la habitación ' || p_id_habitacion ||
        ' no está disponible entre el ' || TO_CHAR(v_in, 'DD/MM/YYYY') ||
        ' y el ' || TO_CHAR(v_out, 'DD/MM/YYYY') ||
        '; se cruza con la reserva ' || v_conflicto || '.');
    END IF;

    -- 6. Tarifas: fn_valor_estadia lanza -20012 si alguna noche no
    --    tiene tarifa, antes de insertar nada.
    v_valor := fn_valor_estadia(p_id_habitacion, v_in, v_out);

    -- 7. Cabecera. Una reserva de una habitación tiene las mismas
    --    fechas en la cabecera y en la línea (RN5).
    INSERT INTO reserva (id_cliente, id_alojamiento, fecha_reserva,
                         fecha_checkin, fecha_checkout, estado)
    VALUES (p_id_cliente, v_id_alojamiento, SYSDATE,
            v_in, v_out, 'PENDIENTE')
    RETURNING id_reserva INTO p_id_reserva;

    -- 8. Línea de la habitación (aquí se dispara TRG_RESHAB_NO_SOLAPE)
    INSERT INTO reserva_habitacion (id_reserva, id_habitacion,
                                    fecha_checkin, fecha_checkout, num_huespedes)
    VALUES (p_id_reserva, p_id_habitacion, v_in, v_out, p_num_huespedes)
    RETURNING id_reserva_hab INTO v_id_reserva_hab;

    -- 9. Una fila por noche con la tarifa de su temporada, congelada (RN9)
    FOR i IN 0 .. (v_out - v_in) - 1 LOOP
      v_tarifa := fn_tarifa_noche(p_id_habitacion, v_in + i);

      INSERT INTO reserva_noche (id_reserva_hab, fecha_noche, id_tarifa, valor_noche)
      VALUES (v_id_reserva_hab, v_in + i, v_tarifa.id_tarifa, v_tarifa.valor_noche);
    END LOOP;

  EXCEPTION
    WHEN OTHERS THEN
      -- Deshace solo lo insertado por este procedimiento y propaga el
      -- error original (con su código propio) a quien lo llamó.
      ROLLBACK TO sp_crear_reserva_inicio;
      p_id_reserva := NULL;
      RAISE;
  END sp_crear_reserva;


  /* -------------------------------------------------------------------
     2.4 sp_liquidacion_mensual                            
     -------------------------------------------------------------------
     QUÉ HACE
     Cierra las cuentas de un mes: una fila por alojamiento en
     LIQUIDACION_MENSUAL, incluidos los que no vendieron nada (quedan en
     cero, para que la liquidación del mes esté completa).

     REGLAS DE CÁLCULO
     Son las mismas de V_INGRESO_RECONOCIDO (RN11), concepto por
     concepto y con la misma fecha para asignar el mes. Así la
     liquidación de un mes y las consultas de la Entrega 1 dan las
     mismas cifras (la prueba 4.4 lo comprueba).
       noches_vendidas = noches del mes en reservas CONFIRMADA o COMPLETADA
       total_estadias  = suma de valor_noche de esas noches
                         (mes = fecha de la noche)
       total_servicios = cantidad x precio_unitario de los servicios de
                         esas reservas (mes = fecha del servicio)
       total_retenido  = en reservas canceladas, lo pagado que no se
                         devolvió: pagos EXITOSO y REEMBOLSADO menos
                         monto_reembolso, solo si es mayor que 0
                         (mes = fecha de CHECK-IN, como en la vista)
       total_neto      = estadías + servicios + retenido
     Las noches se asignan al mes en que se duermen, no al mes en que
     se hizo la reserva: una estadía del 28/12 al 03/01 reparte sus
     noches entre diciembre y enero.

     POR QUÉ "RETENIDO" Y NO "REEMBOLSOS" (decisión 2 del equipo)
     Restar el reembolso de una cancelada descontaría un dinero que la
     liquidación nunca sumó: una reserva de 1.000.000 cancelada con 80 %
     de reembolso saldría en -800.000, cuando el alojamiento se quedó
     con 200.000. Se suma lo retenido, como manda la RN11.

     EL CURSOR
     c_liquidacion es un cursor EXPLÍCITO con dos PARÁMETROS: el primer
     día del mes y el primer día del mes siguiente (rango semiabierto,
     como en el resto del modelo). Devuelve una fila por alojamiento
     con sus cuatro totales ya calculados. Se recorre con OPEN, FETCH y
     CLOSE, y %ROWCOUNT da el número de alojamientos procesados.

     POR QUÉ MERGE
     UNIQUE (id_alojamiento, anio, mes) impide liquidar dos veces el
     mismo mes. Con MERGE, volver a ejecutar la liquidación actualiza
     las filas en vez de fallar: el proceso es re-ejecutable, que es lo
     que se necesita si llega un pago tarde o se corrige una reserva.

     TRANSACCIÓN
     No hace COMMIT: quien lo llama decide (por ejemplo, liquidar todos
     los meses de un año y confirmar al final).
     ------------------------------------------------------------------- */
  PROCEDURE sp_liquidacion_mensual (
    p_anio IN liquidacion_mensual.anio%TYPE,
    p_mes  IN liquidacion_mensual.mes%TYPE
  )
  IS
    v_desde DATE;
    v_hasta DATE;
    v_neto  NUMBER(14,2);
    v_total NUMBER(16,2) := 0;

    -- Cursor explícito con parámetros: una fila por alojamiento.
    CURSOR c_liquidacion (p_desde DATE, p_hasta DATE) IS
      SELECT a.id_alojamiento,
             a.nombre_comercial,
             NVL(e.noches, 0)  AS noches_vendidas,
             NVL(e.total, 0)   AS total_estadias,
             NVL(s.total, 0)   AS total_servicios,
             NVL(c.total, 0)   AS total_retenido
      FROM   alojamiento a
      -- Noches del mes en reservas que generan ingreso
      LEFT JOIN (SELECT r.id_alojamiento,
                        COUNT(*)           AS noches,
                        SUM(rn.valor_noche) AS total
                 FROM   reserva_noche      rn
                 JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
                 JOIN   reserva            r  ON r.id_reserva      = rh.id_reserva
                 WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
                 AND    rn.fecha_noche >= p_desde
                 AND    rn.fecha_noche <  p_hasta
                 GROUP  BY r.id_alojamiento) e
             ON e.id_alojamiento = a.id_alojamiento
      -- Servicios consumidos en el mes
      LEFT JOIN (SELECT r.id_alojamiento,
                        SUM(rs.cantidad * rs.precio_unitario) AS total
                 FROM   reserva_servicio rs
                 JOIN   reserva          r ON r.id_reserva = rs.id_reserva
                 WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
                 AND    rs.fecha_servicio >= p_desde
                 AND    rs.fecha_servicio <  p_hasta
                 GROUP  BY r.id_alojamiento) s
             ON s.id_alojamiento = a.id_alojamiento
      -- Lo retenido de las cancelaciones con check-in en el mes
      -- (mismo cálculo y misma fecha que la parte RETENCION de la vista)
      LEFT JOIN (SELECT r.id_alojamiento,
                        SUM(pg.pagado - ca.monto_reembolso) AS total
                 FROM   cancelacion ca
                 JOIN   reserva     r ON r.id_reserva = ca.id_reserva
                 JOIN  (SELECT id_reserva, SUM(monto) AS pagado
                        FROM   pago
                        WHERE  estado IN ('EXITOSO', 'REEMBOLSADO')
                        GROUP  BY id_reserva) pg ON pg.id_reserva = ca.id_reserva
                 WHERE  r.fecha_checkin >= p_desde
                 AND    r.fecha_checkin <  p_hasta
                 AND    pg.pagado - ca.monto_reembolso > 0
                 GROUP  BY r.id_alojamiento) c
             ON c.id_alojamiento = a.id_alojamiento
      ORDER  BY a.id_alojamiento;

    v_fila c_liquidacion%ROWTYPE;
  BEGIN
    -- 1. Periodo válido (el CHECK de la tabla exige año >= 2024)
    IF p_anio IS NULL OR p_mes IS NULL
       OR p_anio < 2024 OR p_mes NOT BETWEEN 1 AND 12 THEN
      RAISE_APPLICATION_ERROR(c_err_periodo,
        'sp_liquidacion_mensual: periodo inválido (año ' || NVL(TO_CHAR(p_anio), 'nulo') ||
        ', mes ' || NVL(TO_CHAR(p_mes), 'nulo') || '). El año debe ser 2024 o posterior ' ||
        'y el mes, de 1 a 12.');
    END IF;

    v_desde := TO_DATE(p_anio || '-' || LPAD(p_mes, 2, '0') || '-01', 'YYYY-MM-DD');
    v_hasta := ADD_MONTHS(v_desde, 1);

    -- 2. Recorrido explícito del cursor
    OPEN c_liquidacion(v_desde, v_hasta);
    LOOP
      FETCH c_liquidacion INTO v_fila;
      EXIT WHEN c_liquidacion%NOTFOUND;

      v_neto := v_fila.total_estadias + v_fila.total_servicios + v_fila.total_retenido;

      -- 3. Inserta o actualiza la liquidación del alojamiento en el mes
      MERGE INTO liquidacion_mensual l
      USING (SELECT v_fila.id_alojamiento AS id_alojamiento FROM dual) x
      ON    (l.id_alojamiento = x.id_alojamiento AND l.anio = p_anio AND l.mes = p_mes)
      WHEN MATCHED THEN UPDATE SET
             l.noches_vendidas  = v_fila.noches_vendidas,
             l.total_estadias   = v_fila.total_estadias,
             l.total_servicios  = v_fila.total_servicios,
             l.total_retenido   = v_fila.total_retenido,
             l.total_neto       = v_neto,
             l.fecha_generacion = SYSDATE
      WHEN NOT MATCHED THEN INSERT
             (id_alojamiento, anio, mes, noches_vendidas, total_estadias,
              total_servicios, total_retenido, total_neto, fecha_generacion)
      VALUES (v_fila.id_alojamiento, p_anio, p_mes, v_fila.noches_vendidas,
              v_fila.total_estadias, v_fila.total_servicios,
              v_fila.total_retenido, v_neto, SYSDATE);

      v_total := v_total + v_neto;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('Liquidación ' || LPAD(p_mes, 2, '0') || '/' || p_anio || ': ' ||
                         c_liquidacion%ROWCOUNT || ' alojamientos, neto total ' ||
                         TO_CHAR(v_total, 'FM999G999G999G990D00'));
    CLOSE c_liquidacion;

  EXCEPTION
    WHEN OTHERS THEN
      IF c_liquidacion%ISOPEN THEN
        CLOSE c_liquidacion;
      END IF;
      RAISE;
  END sp_liquidacion_mensual;

END pkg_turismouq;
/


/* =====================================================================
   3. VERIFICACIÓN DE COMPILACIÓN
   ---------------------------------------------------------------------
   Las dos filas deben salir con status VALID y la segunda consulta no
   debe devolver filas. Si aparece algún error, la consulta indica la
   línea y el mensaje.
   ===================================================================== */

SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name = 'PKG_TURISMOUQ'
ORDER  BY object_type;

SELECT type, line, position, text
FROM   user_errors
WHERE  name = 'PKG_TURISMOUQ'
ORDER  BY type, sequence;

/* Fin del script del paquete */
