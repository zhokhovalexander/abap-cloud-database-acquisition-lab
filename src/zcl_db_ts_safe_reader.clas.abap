CLASS zcl_db_ts_safe_reader DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_ts_safe_reader IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS:
      c_source_name          TYPE zdb_delta_state-source_name
        VALUE 'PRODUCT_PRICE_SAFE',

       " Laboratory values only.
       " In production, the upper interval must cover the bounded
       " source transaction / visibility lag.
      c_upper_safety_seconds TYPE i
        VALUE 300 ,

       " Lower safety deliberately creates an overlap and may
       " therefore deliver the same after-image more than once.
      c_lower_safety_seconds TYPE i
        VALUE 300 .



    "------------------------------------------------------------
    " 1. Read current safe-delta pointer
    "------------------------------------------------------------
    SELECT SINGLE
      FROM zdb_delta_state
      FIELDS last_changed_at
      WHERE source_name = @c_source_name
      INTO @DATA(lv_last_changed_at).

    IF sy-subrc <> 0.
      out->write(
        |Delta state not found for source { c_source_name }.|
      ).
      RETURN.
    ENDIF.

    IF lv_last_changed_at IS INITIAL.
      out->write( 'Safe timestamp delta is not initialized.' ).
      RETURN.
    ENDIF.

    "------------------------------------------------------------
  " 2. Determine request boundaries
  "
  " Persistent pointer:
  "   LAST_CHANGED_AT
  "
  " Temporary lower boundary:
  "   LAST_CHANGED_AT - lower safety interval
  "
  " Upper boundary:
  "   request start - upper safety interval
  "------------------------------------------------------------
  DATA(lv_request_start) = utclong_current( ).

  DATA(lv_lower_bound) =
    utclong_add(
      val     = lv_last_changed_at
      seconds = - c_lower_safety_seconds
    ).

  DATA(lv_upper_bound) =
    utclong_add(
      val     = lv_request_start
      seconds = - c_upper_safety_seconds
    ).

  out->write(
    |Current LAST_CHANGED_AT = { lv_last_changed_at }|
  ).

  out->write(
    |Lower safety interval  = { c_lower_safety_seconds } seconds|
  ).

  out->write(
    |Lower bound            = { lv_lower_bound }|
  ).

  out->write(
    |Request start          = { lv_request_start }|
  ).

  out->write(
    |Upper safety interval  = { c_upper_safety_seconds } seconds|
  ).

  out->write(
    |Upper bound            = { lv_upper_bound }|
  ).



 "------------------------------------------------------------
  " 3. Check whether a new safe interval exists
  "------------------------------------------------------------
  IF lv_upper_bound <= lv_last_changed_at.
    out->write(
      'Upper bound has not moved beyond the current pointer.'
    ).
    RETURN.
  ENDIF.


  "------------------------------------------------------------
" 4. Read safe interval including lower overlap
"
" LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
"
" The interval between LOWER_BOUND and LAST_CHANGED_AT
" is intentionally re-read. This may produce duplicate
" after-images in different acquisition runs.
"------------------------------------------------------------

  SELECT FROM zdb_src_price
    FIELDS product_id,
           store_group,
           price,
           currency,
           created_seq,
           changed_at,
           is_deleted
    WHERE changed_at >  @lv_lower_bound
      AND changed_at <= @lv_upper_bound
    ORDER BY changed_at, product_id, store_group
    INTO TABLE @DATA(lt_source).

  out->write(
    |Safe timestamp delta: { lines( lt_source ) } rows selected.|
  ).


    "------------------------------------------------------------
    " 5. Persist acquired rows if any
    "------------------------------------------------------------
    DATA lv_run_id TYPE sysuuid_c32.
    IF lt_source IS NOT INITIAL.

      TRY.
          lv_run_id =
            cl_system_uuid=>create_uuid_c32_static( ).

        CATCH cx_uuid_error INTO DATA(lx_uuid).
          out->write(
            |UUID creation failed: { lx_uuid->get_text( ) }|
          ).
          RETURN.
      ENDTRY.

      DATA(lv_acquired_at) = utclong_current( ).

      DATA lt_acq TYPE TABLE OF zdb_acq_price.

      LOOP AT lt_source ASSIGNING FIELD-SYMBOL(<ls_source>).

        APPEND VALUE #(
          client      = sy-mandt
          run_id      = lv_run_id
          product_id  = <ls_source>-product_id
          store_group = <ls_source>-store_group
          load_type   = 'TS_SAFE'
          price       = <ls_source>-price
          currency    = <ls_source>-currency
          created_seq = <ls_source>-created_seq
          changed_at  = <ls_source>-changed_at
          is_deleted  = <ls_source>-is_deleted
          acquired_at = lv_acquired_at
        ) TO lt_acq.

      ENDLOOP.

      INSERT zdb_acq_price FROM TABLE @lt_acq.

      IF sy-subrc <> 0.
        ROLLBACK WORK.
        out->write(
          |Acquisition persistence failed. SY-SUBRC = { sy-subrc }|
        ).
        RETURN.
      ENDIF.

      out->write(
        |Run ID: { lv_run_id }|
      ).

      out->write(
        |Persisted: { lines( lt_acq ) } rows.|
      ).

    ENDIF.

 "------------------------------------------------------------
  " 6. Advance persistent pointer to SAFE UPPER BOUND
  "
  " Important:
  " Lower safety affects only the SELECT lower boundary.
  " It does NOT move the persistent pointer backwards.
  "------------------------------------------------------------
    UPDATE zdb_delta_state
      SET last_changed_at = @lv_upper_bound
      WHERE source_name = @c_source_name.

    IF sy-subrc <> 0.
      ROLLBACK WORK.
      out->write(
        |Safe timestamp pointer update failed. SY-SUBRC = { sy-subrc }|
      ).
      RETURN.
    ENDIF.

    COMMIT WORK.

    IF lt_source IS NOT INITIAL.

     out->write(
         |Run ID: { lv_run_id }|
          ).

     out->write(
         |Persisted: { lines( lt_source ) } rows.|
        ).

    ENDIF.

    out->write(
        |New LAST_CHANGED_AT = { lv_upper_bound }|
        ).


  ENDMETHOD.

ENDCLASS.
