CLASS zcl_db_log_insert DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_log_insert IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    DATA lv_client TYPE zdb_event_count-client.
    DATA lv_source_name TYPE zdb_event_count-source_name.

    lv_client      = sy-mandt.
    lv_source_name = 'PRODUCT_PRICE_LOG'.

    "------------------------------------------------------------
    " 1. Get lock object instance
    "------------------------------------------------------------
    TRY.
        DATA(lo_lock) =
          cl_abap_lock_object_factory=>get_instance(
            iv_name = 'EZDBEVCOUNT'
          ).

      CATCH cx_abap_lock_failure INTO DATA(lx_factory).
        out->write(
          |Lock object initialization failed: { lx_factory->get_text( ) }|
        ).
        RETURN.
    ENDTRY.


    "------------------------------------------------------------
    " 2. Lock counter row
    "
    " Lock key:
    " CLIENT      = current client
    " SOURCE_NAME = PRODUCT_PRICE_LOG
    "------------------------------------------------------------
    TRY.

        lo_lock->enqueue(
          it_parameter = VALUE #(
            ( name  = 'CLIENT'
              value = REF #( lv_client ) )

            ( name  = 'SOURCE_NAME'
              value = REF #( lv_source_name ) )
          )
        ).

      CATCH cx_abap_foreign_lock INTO DATA(lx_foreign).

        out->write(
          |Event counter is locked by another session/user: { lx_foreign->get_text( ) }|
        ).
        RETURN.

      CATCH cx_abap_lock_failure INTO DATA(lx_lock).

        out->write(
          |Event counter lock failed: { lx_lock->get_text( ) }|
        ).
        RETURN.

    ENDTRY.


    "------------------------------------------------------------
    " 3. Read counter only AFTER the lock has been acquired
    "------------------------------------------------------------
    SELECT SINGLE
      FROM zdb_event_count
      FIELDS last_event_seq
      WHERE source_name = @lv_source_name
      INTO @DATA(lv_last_event_seq).

    IF sy-subrc <> 0.

      ROLLBACK WORK.

      TRY.
          lo_lock->dequeue( ).
        CATCH cx_abap_lock_failure.
          " Nothing else to do in this laboratory case
      ENDTRY.

      out->write(
        |Event counter not found for source { lv_source_name }.|
      ).

      RETURN.

    ENDIF.


    DATA(lv_event_seq) = lv_last_event_seq + 1.
    DATA(lv_event_at)  = utclong_current( ).

    out->write(
      |Allocated EVENT_SEQ = { lv_event_seq }|
    ).


    "------------------------------------------------------------
    " 4. Advance counter in the same LUW
    "------------------------------------------------------------
    UPDATE zdb_event_count
      SET last_event_seq = @lv_event_seq
      WHERE source_name = @lv_source_name.

    IF sy-subrc <> 0.

      ROLLBACK WORK.

      TRY.
          lo_lock->dequeue( ).
        CATCH cx_abap_lock_failure.
      ENDTRY.

      out->write( 'Event counter update failed.' ).

      RETURN.

    ENDIF.


    "------------------------------------------------------------
    " 5. Apply business change
    "------------------------------------------------------------
    DATA(ls_price) = VALUE zdb_src_price(
      client      = sy-mandt
      product_id  = 'P1011'
      store_group = 'SOUTH'
      price       = '110.00'
      currency    = 'EUR'
      created_seq = 1012
      changed_at  = lv_event_at
      is_deleted  = ''
    ).

    INSERT zdb_src_price FROM @ls_price.

    IF sy-subrc <> 0.

      ROLLBACK WORK.

      TRY.
          lo_lock->dequeue( ).
        CATCH cx_abap_lock_failure.
      ENDTRY.

      out->write(
        |Source INSERT failed. SY-SUBRC = { sy-subrc }|
      ).

      RETURN.

    ENDIF.


    "------------------------------------------------------------
    " 6. Write change-log event
    "------------------------------------------------------------
    DATA(ls_event) = VALUE zdb_change_log(
      client      = sy-mandt
      source_name = lv_source_name
      event_seq   = lv_event_seq
      product_id  = 'P1011'
      store_group = 'SOUTH'
      operation   = 'I'
      price       = '110.00'
      currency    = 'EUR'
      event_at    = lv_event_at
    ).

    INSERT zdb_change_log FROM @ls_event.

    IF sy-subrc <> 0.

      ROLLBACK WORK.

      TRY.
          lo_lock->dequeue( ).
        CATCH cx_abap_lock_failure.
      ENDTRY.

      out->write(
        |Change-log INSERT failed. SY-SUBRC = { sy-subrc }|
      ).

      RETURN.

    ENDIF.


    "------------------------------------------------------------
    " Manual debugging anchor
    "
    " At this point:
    " - EZDBEVCOUNT is still locked
    " - counter change is uncommitted
    " - business INSERT is uncommitted
    " - change-log INSERT is uncommitted
    "
    " Do NOT move the DEQUEUE before COMMIT.
    "------------------------------------------------------------
    DATA(lv_debug_anchor) = abap_true.


    "------------------------------------------------------------
    " 7. Commit all three changes atomically
    "------------------------------------------------------------
    COMMIT WORK.


    "------------------------------------------------------------
    " 8. Release counter lock only AFTER COMMIT
    "------------------------------------------------------------
    TRY.
        lo_lock->dequeue( ).

      CATCH cx_abap_lock_failure INTO DATA(lx_dequeue).

        out->write(
          |Commit succeeded, but lock release failed: { lx_dequeue->get_text( ) }|
        ).

        RETURN.

    ENDTRY.


    out->write(
      |Committed event { lv_event_seq }: P1011/SOUTH INSERT.|
    ).

  ENDMETHOD.

ENDCLASS.
