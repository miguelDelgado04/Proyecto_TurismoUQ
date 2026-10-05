/* =====================================================================
   PROYECTO INTEGRADOR - BASES DE DATOS II
   TurismoUQ: plataforma de reservas de alojamientos en el Quindío
   ---------------------------------------------------------------------
   Archivo   : 03_CONSULTAS_TurismoUQ.sql
   Entrega   : 1 - Siete consultas de análisis
   Requiere  : 01_DDL_TurismoUQ.sql y 02_CARGA_TurismoUQ.sql ejecutados
   Motor     : Oracle Database 21c XE (también corre en 23ai Free)
   ---------------------------------------------------------------------
   CONTENIDO
     0. Vista base V_INGRESO_RECONOCIDO (definición única de ingreso)
     1. Ocupación por municipio y mes ........................ PIVOT
     2. Ingresos por municipio, tipo y temporada ............. ROLLUP + GROUPING
     3. Top 3 alojamientos por ingreso en cada municipio ..... RANK + PARTITION BY
     4. Variación de ingresos mes contra mes ................. LAG
     5. Desempeño por tipo en un rango de fechas ............. variables de enlace
     6. Reservas, llegadas y salidas por día de la semana .... UNPIVOT
     7. Calificación frente a ocupación (consulta libre) ..... MEDIAN + CASE

   CÓMO EJECUTARLO
   Conectado como TURISMOUQ, ejecutar todo con F5 (Ejecutar script).
   Cada consulta también se puede ejecutar sola con Ctrl+Enter; la
   consulta 5 pedirá entonces los valores de las variables de enlace.

   AÑO DE ANÁLISIS
   Las consultas 1, 2, 3 y 7 usan el año 2025 porque es el único año
   completo de los datos (2024 arranca con menos volumen y 2026 llega
   hasta la fecha de corte, 30/09/2026).
   ===================================================================== */

SET LINESIZE 250
SET PAGESIZE 100

/* =====================================================================
   0. VISTA BASE: V_INGRESO_RECONOCIDO
   ---------------------------------------------------------------------
   Implementa la RN11 (definición única de ingreso) para que las
   consultas 2, 3 y 4 sumen exactamente lo mismo. Una fila por cada
   peso que la plataforma reconoce como ingreso, con su fecha y su
   temporada:
   
     ESTADIA   : cada noche de reservas CONFIRMADA o COMPLETADA, con el
                 valor congelado en RESERVA_NOCHE y la temporada de la
                 tarifa aplicada.
                 
     SERVICIO  : cada línea de servicio de esas reservas, en la
                 temporada que contiene la fecha del servicio.
                 
     RETENCION : en reservas CANCELADA, lo pagado que no se devolvió
                 (pagos exitosos + reembolsados - monto reembolsado),
                 asignado a la temporada de la fecha de llegada.
   ===================================================================== */
   
CREATE OR REPLACE VIEW v_ingreso_reconocido AS
-- Estadías: una fila por noche
SELECT r.id_reserva,
       r.id_alojamiento,
       a.id_municipio,
       a.id_tipo_alojamiento,
       rn.fecha_noche                     AS fecha,
       t.id_temporada,
       t.id_tipo_temporada,
       CAST('ESTADIA' AS VARCHAR2(10))    AS concepto,
       rn.valor_noche                     AS monto
FROM   reserva_noche rn
JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
JOIN   reserva r             ON r.id_reserva      = rh.id_reserva
JOIN   alojamiento a         ON a.id_alojamiento  = r.id_alojamiento
JOIN   tarifa ta             ON ta.id_tarifa      = rn.id_tarifa
JOIN   temporada t           ON t.id_temporada    = ta.id_temporada
WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
UNION ALL
-- Servicios: una fila por línea de servicio
SELECT r.id_reserva,
       r.id_alojamiento,
       a.id_municipio,
       a.id_tipo_alojamiento,
       rs.fecha_servicio,
       t.id_temporada,
       t.id_tipo_temporada,
       CAST('SERVICIO' AS VARCHAR2(10)),
       rs.cantidad * rs.precio_unitario
FROM   reserva_servicio rs
JOIN   reserva r     ON r.id_reserva     = rs.id_reserva
JOIN   alojamiento a ON a.id_alojamiento = r.id_alojamiento
JOIN   temporada t   ON rs.fecha_servicio BETWEEN t.fecha_inicio AND t.fecha_fin
WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
UNION ALL
-- Retención de cancelaciones: una fila por reserva cancelada con dinero retenido
SELECT r.id_reserva,
       r.id_alojamiento,
       a.id_municipio,
       a.id_tipo_alojamiento,
       r.fecha_checkin,
       t.id_temporada,
       t.id_tipo_temporada,
       CAST('RETENCION' AS VARCHAR2(10)),
       p.pagado - c.monto_reembolso
FROM   cancelacion c
JOIN   reserva r     ON r.id_reserva     = c.id_reserva
JOIN   alojamiento a ON a.id_alojamiento = r.id_alojamiento
JOIN   (SELECT id_reserva, SUM(monto) AS pagado
        FROM   pago
        WHERE  estado IN ('EXITOSO', 'REEMBOLSADO')
        GROUP  BY id_reserva) p ON p.id_reserva = c.id_reserva
JOIN   temporada t   ON r.fecha_checkin BETWEEN t.fecha_inicio AND t.fecha_fin
WHERE  p.pagado - c.monto_reembolso > 0;

COMMENT ON TABLE v_ingreso_reconocido IS
  'Ingreso reconocido (RN11): noches y servicios de reservas confirmadas o completadas, más lo retenido en cancelaciones.';

/* =====================================================================
   CONSULTA 1 · OCUPACIÓN POR MUNICIPIO Y MES (PIVOT)
   ---------------------------------------------------------------------
   Pregunta : ¿Qué porcentaje de su capacidad ocupa cada municipio en
              cada mes de 2025?
              
   Cálculo  : ocupación = noches vendidas / noches disponibles x 100
              noches vendidas    = noches de reservas confirmadas o
                                   completadas (RESERVA_NOCHE)
                                   
              noches disponibles = habitaciones del municipio x días
                                   del mes
                                   
   Técnica  : la subconsulta BASE deja una fila por municipio y mes;
              PIVOT convierte los 12 meses en columnas. Como PIVOT exige
              una función de agregación y ya hay un solo valor por
              celda, se usa MAX.
              
   Lectura  : las columnas JUN, JUL y DIC deben destacar (temporadas
              altas); FEB y SEP, ser las más bajas.
   ===================================================================== */
WITH noches AS (
  -- Noches vendidas por municipio y mes
  SELECT a.id_municipio,
         EXTRACT(MONTH FROM rn.fecha_noche) AS mes,
         COUNT(*)                           AS noches_vendidas
  FROM   reserva_noche rn
  JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
  JOIN   reserva r             ON r.id_reserva      = rh.id_reserva
  JOIN   alojamiento a         ON a.id_alojamiento  = r.id_alojamiento
  WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
  AND    rn.fecha_noche >= DATE '2025-01-01'
  AND    rn.fecha_noche <  DATE '2026-01-01'
  GROUP  BY a.id_municipio, EXTRACT(MONTH FROM rn.fecha_noche)
),
capacidad AS (
  -- Habitaciones de cada municipio
  SELECT a.id_municipio, COUNT(*) AS habitaciones
  FROM   habitacion h
  JOIN   alojamiento a ON a.id_alojamiento = h.id_alojamiento
  GROUP  BY a.id_municipio
),
meses AS (
  -- Los 12 meses de 2025 con su número de días
  SELECT LEVEL AS mes,
         EXTRACT(DAY FROM LAST_DAY(ADD_MONTHS(DATE '2025-01-01', LEVEL - 1))) AS dias
  FROM   dual
  CONNECT BY LEVEL <= 12
),
base AS (
  -- Una fila por municipio y mes (incluye meses sin ventas con 0 %)
  SELECT m.nombre AS municipio,
         me.mes,
         ROUND(100 * NVL(n.noches_vendidas, 0) / (c.habitaciones * me.dias), 1) AS ocupacion
  FROM   municipio m
  JOIN   capacidad c ON c.id_municipio = m.id_municipio
  CROSS  JOIN meses me
  LEFT   JOIN noches n ON n.id_municipio = m.id_municipio
                      AND n.mes          = me.mes
)
SELECT *
FROM   base
PIVOT (
  MAX(ocupacion)
  FOR mes IN (1 AS ene, 2 AS feb, 3 AS mar, 4 AS abr,  5 AS may,  6 AS jun,
              7 AS jul, 8 AS ago, 9 AS sep, 10 AS oct, 11 AS nov, 12 AS dic)
)
ORDER  BY municipio;

/* =====================================================================
   CONSULTA 2 · INGRESOS POR MUNICIPIO, TIPO Y TEMPORADA
               (ROLLUP + GROUPING)
   ---------------------------------------------------------------------
   Pregunta : ¿Cuánto ingresó en 2025 cada tipo de alojamiento de cada
              municipio en temporada alta, media y baja, con subtotales
              por tipo, por municipio y total general?
              
   Técnica  : ROLLUP(municipio, tipo, temporada) genera, además del
              detalle, tres niveles de subtotal:
                (municipio, tipo)  -> subtotal del tipo en el municipio
                (municipio)        -> subtotal del municipio
                ()                 -> total general
                
              En las filas de subtotal la columna agrupada vale NULL;
              GROUPING(col) devuelve 1 en esos casos y permite poner una
              etiqueta en lugar del NULL. GROUPING_ID resume el nivel:
                0 detalle | 1 subtotal tipo | 3 subtotal municipio |
                7 total general
                
   Por qué ROLLUP y no CUBE: la jerarquía municipio > tipo > temporada
   es natural para la gerencia.
   
   CUBE agregaría también los cruces sin jerarquía (por ejemplo, total por temporada sin municipio), útil pero mucho más extenso.
   ===================================================================== */
   
SELECT CASE WHEN GROUPING(m.nombre) = 1 THEN '*** TOTAL GENERAL ***'
            ELSE m.nombre
       END AS municipio,
       CASE WHEN GROUPING(m.nombre)  = 1 THEN NULL
            WHEN GROUPING(ta.nombre) = 1 THEN '** Subtotal municipio **'
            ELSE ta.nombre
       END AS tipo_alojamiento,
       CASE WHEN GROUPING(ta.nombre) = 1 THEN NULL
            WHEN GROUPING(tt.nombre) = 1 THEN '* Subtotal tipo *'
            ELSE tt.nombre
       END AS temporada,
       SUM(v.monto)                              AS ingresos,
       GROUPING_ID(m.nombre, ta.nombre, tt.nombre) AS nivel
FROM   v_ingreso_reconocido v
JOIN   municipio m         ON m.id_municipio         = v.id_municipio
JOIN   tipo_alojamiento ta ON ta.id_tipo_alojamiento = v.id_tipo_alojamiento
JOIN   tipo_temporada tt   ON tt.id_tipo_temporada   = v.id_tipo_temporada
WHERE  v.fecha >= DATE '2025-01-01'
AND    v.fecha <  DATE '2026-01-01'
GROUP  BY ROLLUP (m.nombre, ta.nombre, tt.nombre)
ORDER  BY GROUPING(m.nombre),  m.nombre,
          GROUPING(ta.nombre), ta.nombre,
          GROUPING(tt.nombre), DECODE(tt.nombre, 'ALTA', 1, 'MEDIA', 2, 'BAJA', 3);

/* =====================================================================
   CONSULTA 3 · LOS 3 ALOJAMIENTOS DE MAYOR INGRESO EN CADA MUNICIPIO
               (RANK + PARTITION BY)
   ---------------------------------------------------------------------
   Pregunta : ¿Cuáles son los alojamientos más rentables dentro de cada
              municipio en 2025 y qué parte del ingreso del municipio
              concentra cada uno?
              
   Técnica  : RANK() OVER (PARTITION BY municipio ORDER BY ingresos DESC)
              numera los alojamientos de cada municipio por separado:
              la numeración vuelve a empezar en 1 en cada municipio.
              Con RANK, dos alojamientos empatados reciben el mismo
              puesto y el siguiente se salta (1, 1, 3); por eso un
              municipio podría mostrar más de 3 filas si hay empate en
              el tercer puesto.
              
              RATIO_TO_REPORT calcula la participación de cada
              alojamiento en el ingreso total de su municipio.
              Los municipios con menos de 3 alojamientos (Pijao,
              Córdoba, Génova, Buenavista) muestran solo los que tienen.
              
   Nota     : el filtro puesto <= 3 se aplica en la consulta externa
              porque una función analítica no se puede usar en el WHERE
              de la misma consulta donde se calcula.
   ===================================================================== */
   
WITH ingresos AS (
  SELECT v.id_municipio,
         v.id_alojamiento,
         SUM(v.monto) AS ingresos
  FROM   v_ingreso_reconocido v
  WHERE  v.fecha >= DATE '2025-01-01'
  AND    v.fecha <  DATE '2026-01-01'
  GROUP  BY v.id_municipio, v.id_alojamiento
),
ranking AS (
  SELECT m.nombre                AS municipio,
         a.nombre_comercial      AS alojamiento,
         ta.nombre               AS tipo,
         i.ingresos,
         RANK() OVER (PARTITION BY i.id_municipio ORDER BY i.ingresos DESC)            AS puesto,
         ROUND(100 * RATIO_TO_REPORT(i.ingresos) OVER (PARTITION BY i.id_municipio), 1) AS pct_del_municipio
  FROM   ingresos i
  JOIN   municipio m         ON m.id_municipio         = i.id_municipio
  JOIN   alojamiento a       ON a.id_alojamiento       = i.id_alojamiento
  JOIN   tipo_alojamiento ta ON ta.id_tipo_alojamiento = a.id_tipo_alojamiento
)
SELECT municipio, puesto, alojamiento, tipo, ingresos, pct_del_municipio
FROM   ranking
WHERE  puesto <= 3
ORDER  BY municipio, puesto;

/* =====================================================================
   CONSULTA 4 · VARIACIÓN DE INGRESOS MES CONTRA MES (LAG)
   ---------------------------------------------------------------------
   Pregunta : ¿Cuánto subieron o bajaron los ingresos de la plataforma
              cada mes frente al mes anterior y frente al mismo mes del
              año anterior?
              
   Técnica  : LAG(ingresos, 1) trae el valor de la fila anterior según
              el orden por mes, sin necesidad de un self-join.
              
              LAG(ingresos, 12) trae el mismo mes del año anterior
              (variación interanual), que separa el crecimiento real
              del efecto de la temporada.
              
              El primer mes no tiene anterior: LAG devuelve NULL y la
              variación queda vacía. NULLIF evita dividir por cero.
              
   Rango    : de enero de 2024 a septiembre de 2026 (fecha de corte),
              para no comparar contra meses incompletos.
   ===================================================================== */
   
WITH mensual AS (
  SELECT TRUNC(v.fecha, 'MM') AS mes,
         SUM(v.monto)         AS ingresos
  FROM   v_ingreso_reconocido v
  WHERE  v.fecha >= DATE '2024-01-01'
  AND    v.fecha <  DATE '2026-10-01'
  GROUP  BY TRUNC(v.fecha, 'MM')
)

SELECT TO_CHAR(mes, 'YYYY-MM')                                       AS mes,
       TO_CHAR(ingresos,     '999G999G999G990')                      AS ingresos,
       TO_CHAR(mes_anterior, '999G999G999G990')                      AS mes_anterior,
       TO_CHAR(ingresos - mes_anterior, '999G999G999G990')           AS variacion,
       TO_CHAR(ROUND(100 * (ingresos - mes_anterior)
                         / NULLIF(mes_anterior, 0), 1), '99990D0')   AS Var_MES,
       TO_CHAR(ROUND(100 * (ingresos - mismo_mes_anio_ant)
                         / NULLIF(mismo_mes_anio_ant, 0), 1), '99990D0') AS Var_ANUAL
FROM  (SELECT mes,
              ingresos,
              LAG(ingresos, 1)  OVER (ORDER BY mes) AS mes_anterior,
              LAG(ingresos, 12) OVER (ORDER BY mes) AS mismo_mes_anio_ant
       FROM   mensual)
ORDER  BY mes;

/* =====================================================================
   CONSULTA 5 · DESEMPEÑO POR TIPO DE ALOJAMIENTO EN UN RANGO DE FECHAS
               (CONSULTA PARAMETRIZADA CON VARIABLES DE ENLACE)
   ---------------------------------------------------------------------
   Pregunta : Para el rango de fechas que escoja la gerencia, ¿cómo le
              fue a cada tipo de alojamiento en ocupación, tarifa
              promedio y RevPAR?
              
   Indicadores (estándar de la industria hotelera):
     Ocupación % = noches vendidas / noches disponibles x 100
     
     Tarifa promedio (ADR) = ingreso de estadías / noches vendidas
     
     RevPAR = ingreso de estadías / noches disponibles
              (combina precio y ocupación: un tipo puede tener tarifa
              alta pero RevPAR bajo si casi no se vende)
              
   Técnica  : el rango llega en las variables de enlace :b_fecha_ini y
              :b_fecha_fin. Oracle comparte el mismo plan de ejecución
              para cualquier rango (no se re-analiza la sentencia por
              cada valor), y se evita la inyección de SQL que ocurriría
              al concatenar fechas en el texto.
              
              VARIABLE no admite el tipo DATE, por eso las fechas se
              pasan como texto 'YYYY-MM-DD' y se convierten con TO_DATE
              una sola vez en el CTE RANGO.
              
   Para cambiar el rango, editen los dos EXEC. Ejemplo: temporada de
   mitad de año 2025.
   ===================================================================== */
   
VARIABLE b_fecha_ini VARCHAR2(10)
VARIABLE b_fecha_fin VARCHAR2(10)
EXEC :b_fecha_ini := '2025-06-20';
EXEC :b_fecha_fin := '2025-07-13';

WITH rango AS (
  SELECT TO_DATE(:b_fecha_ini, 'YYYY-MM-DD') AS ini,
         TO_DATE(:b_fecha_fin, 'YYYY-MM-DD') AS fin
  FROM   dual
),
vendidas AS (
  -- Noches vendidas e ingreso de estadías dentro del rango (ambos extremos incluidos)
  SELECT a.id_tipo_alojamiento,
         COUNT(*)            AS noches_vendidas,
         SUM(rn.valor_noche) AS ingreso_estadias
  FROM   reserva_noche rn
  JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
  JOIN   reserva r             ON r.id_reserva      = rh.id_reserva
  JOIN   alojamiento a         ON a.id_alojamiento  = r.id_alojamiento
  CROSS  JOIN rango g
  WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
  AND    rn.fecha_noche BETWEEN g.ini AND g.fin
  GROUP  BY a.id_tipo_alojamiento
),
disponibles AS (
  -- Noches disponibles = habitaciones del tipo x días del rango
  SELECT a.id_tipo_alojamiento,
         COUNT(*) * (g.fin - g.ini + 1) AS noches_disponibles
  FROM   habitacion h
  JOIN   alojamiento a ON a.id_alojamiento = h.id_alojamiento
  CROSS  JOIN rango g
  GROUP  BY a.id_tipo_alojamiento, g.ini, g.fin
)
SELECT ta.nombre                                                           AS tipo_alojamiento,
       d.noches_disponibles,
       NVL(v.noches_vendidas, 0)                                           AS noches_vendidas,
       ROUND(100 * NVL(v.noches_vendidas, 0) / d.noches_disponibles, 1)    AS ocupacion_pct,
       NVL(v.ingreso_estadias, 0)                                          AS ingreso_estadias,
       ROUND(v.ingreso_estadias / NULLIF(v.noches_vendidas, 0))            AS tarifa_promedio_adr,
       ROUND(NVL(v.ingreso_estadias, 0) / d.noches_disponibles)            AS revpar
FROM   disponibles d
JOIN   tipo_alojamiento ta ON ta.id_tipo_alojamiento = d.id_tipo_alojamiento
LEFT   JOIN vendidas v     ON v.id_tipo_alojamiento  = d.id_tipo_alojamiento
ORDER  BY revpar DESC;


/* =====================================================================
   CONSULTA 6 · RESERVAS, LLEGADAS Y SALIDAS POR DÍA DE LA SEMANA
               (UNPIVOT)
   ---------------------------------------------------------------------
   Pregunta : ¿Qué días de la semana concentran las reservas hechas,
              las llegadas y las salidas? Sirve para dimensionar el
              personal de recepción y programar campañas de venta.
              
   Técnica  : RESERVA tiene tres fechas en COLUMNAS distintas
              (fecha_reserva, fecha_checkin, fecha_checkout). 
              
              UNPIVOT las convierte en FILAS: cada reserva produce tres filas
              con las columnas EVENTO (qué fecha es) y FECHA (su valor).
              
              Así se pueden agrupar los tres eventos con un solo
              GROUP BY, en lugar de tres consultas unidas con UNION ALL.
              
              Las columnas que no se transforman (como estado) siguen
              disponibles para filtrar.
              
              El día de la semana se calcula como fecha - TRUNC(fecha,'IW')
              (0 = lunes ... 6 = domingo), que no depende de la
              configuración regional de la sesión.
              
              RATIO_TO_REPORT da el porcentaje de cada día dentro de su
              evento.
   ===================================================================== */
   
SELECT evento,
       TO_CHAR(fecha, 'fmDay', 'NLS_DATE_LANGUAGE = SPANISH')            AS dia_semana,
       COUNT(*)                                                         AS cantidad,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (PARTITION BY evento), 1) AS pct_del_evento
FROM   reserva
UNPIVOT (
  fecha FOR evento IN (fecha_reserva  AS '1. RESERVA HECHA',
                       fecha_checkin  AS '2. LLEGADA',
                       fecha_checkout AS '3. SALIDA')
)
WHERE  estado <> 'CANCELADA'
GROUP  BY evento,
          TRUNC(fecha) - TRUNC(fecha, 'IW'),
          TO_CHAR(fecha, 'fmDay', 'NLS_DATE_LANGUAGE = SPANISH')
ORDER  BY evento, TRUNC(fecha) - TRUNC(fecha, 'IW');

/* =====================================================================
   CONSULTA 7 · CALIFICACIÓN FRENTE A OCUPACIÓN (CONSULTA LIBRE)
   ---------------------------------------------------------------------
   Pregunta de negocio:
   
     ¿Qué alojamientos están bien calificados pero se venden poco
     ("joyas escondidas" que conviene promocionar) y cuáles se venden
     mucho pero tienen malas reseñas (riesgo para la reputación de la
     plataforma)?
     
   Responde además a la necesidad de la sección 1.8 que no cubren las
   consultas obligatorias: "qué tan bien calificados están los
   alojamientos según sus reseñas".
   
   Técnica  :
     - Calificación promedio, número de reseñas y porcentaje de reseñas
       negativas (1 o 2 estrellas) de cada alojamiento.
       
     - Ocupación de 2025 de cada alojamiento.
     
     - MEDIAN(...) OVER () calcula la mediana de toda la plataforma sin
       agrupar; se usa la mediana y no el promedio para que los
       valores extremos no la desplacen.
       
     - CASE clasifica cada alojamiento en uno de cuatro segmentos
       según esté por encima o por debajo de ambas medianas.
       
     - Solo se consideran alojamientos con al menos 10 reseñas, para
       que el promedio sea representativo.
   ===================================================================== */
   
WITH resenas AS (
  SELECT r.id_alojamiento,
         COUNT(*)                                                         AS num_resenas,
         ROUND(AVG(re.calificacion), 2)                                   AS calificacion,
         ROUND(100 * SUM(CASE WHEN re.calificacion <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_negativas
  FROM   resena re
  JOIN   reserva r ON r.id_reserva = re.id_reserva
  GROUP  BY r.id_alojamiento
),
habitaciones AS (
  SELECT id_alojamiento, COUNT(*) AS num_habitaciones
  FROM   habitacion
  GROUP  BY id_alojamiento
),
vendidas AS (
  SELECT r.id_alojamiento, COUNT(*) AS noches_vendidas
  FROM   reserva_noche rn
  JOIN   reserva_habitacion rh ON rh.id_reserva_hab = rn.id_reserva_hab
  JOIN   reserva r             ON r.id_reserva      = rh.id_reserva
  WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
  AND    rn.fecha_noche >= DATE '2025-01-01'
  AND    rn.fecha_noche <  DATE '2026-01-01'
  GROUP  BY r.id_alojamiento
),
base AS (
  SELECT m.nombre                                                          AS municipio,
         ta.nombre                                                         AS tipo,
         a.nombre_comercial                                                AS alojamiento,
         re.num_resenas,
         re.calificacion,
         re.pct_negativas,
         ROUND(100 * NVL(v.noches_vendidas, 0) / (h.num_habitaciones * 365), 1) AS ocupacion_2025
  FROM   alojamiento a
  JOIN   municipio m         ON m.id_municipio         = a.id_municipio
  JOIN   tipo_alojamiento ta ON ta.id_tipo_alojamiento = a.id_tipo_alojamiento
  JOIN   habitaciones h      ON h.id_alojamiento       = a.id_alojamiento
  JOIN   resenas re          ON re.id_alojamiento      = a.id_alojamiento
  LEFT   JOIN vendidas v     ON v.id_alojamiento       = a.id_alojamiento
  WHERE  re.num_resenas >= 10
),
con_medianas AS (
  SELECT b.*,
         MEDIAN(b.calificacion)   OVER () AS mediana_calificacion,
         MEDIAN(b.ocupacion_2025) OVER () AS mediana_ocupacion
  FROM   base b
)
SELECT CASE
         WHEN calificacion >= mediana_calificacion AND ocupacion_2025 >= mediana_ocupacion
           THEN '1. ESTRELLA: mantener'
         WHEN calificacion >= mediana_calificacion
           THEN '2. JOYA ESCONDIDA: promocionar'
         WHEN ocupacion_2025 >= mediana_ocupacion
           THEN '3. POPULAR MAL CALIFICADO: revisar servicio'
         ELSE    '4. EN RIESGO: plan de mejora'
       END AS segmento,
       municipio,
       tipo,
       alojamiento,
       num_resenas,
       calificacion,
       pct_negativas,
       ocupacion_2025
FROM   con_medianas
ORDER  BY segmento, calificacion DESC;

/* Fin del script de consultas */